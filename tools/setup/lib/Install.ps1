# CadMath 安装工具 · 安装 / 更新 / 卸载（含事务与回滚）
Set-StrictMode -Version 2

function Get-StateFile { param([string]$StateRoot) return (Join-Path $StateRoot 'state.json') }
function Get-JournalFile { param([string]$StateRoot) return (Join-Path $StateRoot 'pending.json') }
function Get-PayloadRoot { param([string]$StateRoot) return (Join-Path $StateRoot 'payload') }
function Get-PayloadDir { param([string]$StateRoot, [string]$Version) return (Join-Path (Get-PayloadRoot -StateRoot $StateRoot) $Version) }
function Get-BackupRoot { param([string]$StateRoot) return (Join-Path $StateRoot 'backups') }

function Read-InstallState {
    param([string]$StateRoot)
    $path = Get-StateFile -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ schemaVersion = 1; installedVersion = $null; payloadPath = $null; instances = @() }
    }
    return (Read-JsonFile -Path $path)
}

function Save-InstallState {
    param([string]$StateRoot, $State)
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $path = Get-StateFile -StateRoot $StateRoot
    $temp = $path + '.tmp'
    $json = $State | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Move-Item -LiteralPath $temp -Destination $path
}

function Write-Journal {
    param([string]$StateRoot, $Journal)
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $path = Get-JournalFile -StateRoot $StateRoot
    $json = $Journal | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Read-Journal {
    param([string]$StateRoot)
    $path = Get-JournalFile -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Read-JsonFile -Path $path) } catch { return $null }
}

function Clear-Journal {
    param([string]$StateRoot)
    $path = Get-JournalFile -StateRoot $StateRoot
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Resolve-BundleFromArchive {
    param([string]$Zip, [string]$WorkRoot)
    $target = Join-Path $WorkRoot 'extract'
    $null = Expand-CadBundleArchive -Zip $Zip -Destination $target
    $manifest = Get-ChildItem -LiteralPath $target -Recurse -Filter 'PackageContents.xml' -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1
    if ($manifest -eq $null) { throw '安装包里没有找到 PackageContents.xml。' }
    return $manifest.Directory.FullName
}

function Test-BundleFiles {
    param([string]$BundleRoot, $Files)
    if ($Files -eq $null -or @($Files).Count -eq 0) {
        Write-Warn -Stage 'VERIFY' '发行清单没有 files 清单，跳过逐文件校验。'
        return
    }
    $root = [IO.Path]::GetFullPath($BundleRoot).TrimEnd('\')
    foreach ($file in @($Files)) {
        $relative = ([string]$file.path).Replace('/', '\')
        $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw ('发行清单里的路径越界：{0}' -f $file.path)
        }
        if (-not (Test-Path -LiteralPath $path)) { throw ('安装包缺少清单里的文件：{0}' -f $file.path) }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ne ([string]$file.sha256).ToUpperInvariant()) { throw ('文件校验失败：{0}' -f $file.path) }
    }
    Write-Info -Stage 'VERIFY' ('逐文件校验通过：{0} 个文件' -f @($Files).Count)
}

function Copy-BundleToPayload {
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw ('目标负载目录已存在：{0}' -f $Destination) }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-OwnedDirectories {
    param([string]$PayloadDir)
    $result = New-Object System.Collections.Generic.List[string]
    $win64 = Join-Path $PayloadDir 'Contents\Win64'
    if (Test-Path -LiteralPath $win64) { $result.Add($win64) }
    $adapters = Join-Path $win64 'Adapters'
    if (Test-Path -LiteralPath $adapters) { $result.Add($adapters) }
    return $result.ToArray()
}

function Install-CadMathPackage {
    param(
        [Parameter(Mandatory)]$Setup,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)]$Instances,
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$Architecture = 'x64',
        [string]$ZipSha256,
        [switch]$IsUpdate
    )
    $transactionId = [guid]::NewGuid().ToString('N')
    $work = Join-Path $env:TEMP ('cadmath-setup-' + $transactionId)
    $journal = $null
    $payloadStage = $null
    $payloadFinal = Get-PayloadDir -StateRoot $StateRoot -Version $Setup.releaseVersion
    $previousPayload = $null
    $stateBefore = $null
    $plan = New-Object System.Collections.Generic.List[object]
    # 允许调用方传"实例"或"{Instance,Adapter} 计划项"两种形状。
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Instances) {
        if ($item -eq $null) { continue }
        if ($item.PSObject.Properties['Instance']) { $targets.Add($item.Instance) } else { $targets.Add($item) }
    }
    if ($targets.Count -eq 0) { return [pscustomobject]@{ Success = $false; Error = '没有指定要安装的实例。'; Rollback = 'not-started' } }
    try {
        Assert-CadClosed
        New-Item -ItemType Directory -Path $work -Force | Out-Null

        # 1. 解析负载来源并校验完整性
        $bundleSource = $SourcePath
        if ($SourcePath -like '*.zip') {
            $expectedZip = $ZipSha256
            if (-not $expectedZip -and $Setup.zip -and $Setup.zip.PSObject.Properties['sha256']) {
                $expectedZip = [string]$Setup.zip.sha256
            }
            if ($expectedZip) {
                Write-Info -Stage 'VERIFY' ('校验安装包 SHA-256：{0}' -f (Split-Path $SourcePath -Leaf))
                $null = Test-FileSha256 -Path $SourcePath -Expected $expectedZip
                Write-Info -Stage 'VERIFY' '安装包 SHA-256 校验通过'
            } else {
                Write-Warn -Stage 'VERIFY' '本次没有拿到安装包的校验值，改为逐个文件校验。'
            }
            $bundleSource = Resolve-BundleFromArchive -Zip $SourcePath -WorkRoot $work
        }
        $bundleInfo = Get-BundleInfo -Bundle $bundleSource
        Test-BundleFiles -BundleRoot $bundleInfo.Bundle -Files $Setup.files
        if ($bundleInfo.Version -ne $Setup.releaseVersion) {
            throw ('包版本 {0} 与发行清单 {1} 不一致。' -f $bundleInfo.Version, $Setup.releaseVersion)
        }
        $runtime = Read-RuntimeManifest -Path $bundleInfo.Config
        Write-Info -Stage 'VERIFY' ('包校验通过：{0} {1}，运行时清单 {2} 个适配器' -f $bundleInfo.Name, $bundleInfo.Version, @($runtime.adapters).Count)

        # 2. 逐实例匹配
        foreach ($instance in $targets) {
            $match = Select-AdapterForInstance -Setup $Setup -Instance $instance -Architecture $Architecture
            if ($match.Status -ne 'matched') {
                throw ('{0}：{1}' -f $instance.Label, $(if ($match.Status -eq 'ambiguous') { $match.Error } else { '没有可用适配器（' + (Get-RejectionSummary -Rejections $match.Rejections) + '）' }))
            }
            $plan.Add([pscustomobject]@{ Instance = $instance; Adapter = $match.Adapter })
        }
        Write-Info -Stage 'MATCH' ('计划安装到 {0} 个实例：{1}' -f $plan.Count, (($plan | ForEach-Object { $_.Instance.Label + ' → ' + $_.Adapter.id }) -join '；'))

        # 3. 事务开始前快照
        $stateBefore = Read-InstallState -StateRoot $StateRoot
        $snapshots = New-Object System.Collections.Generic.List[object]
        foreach ($item in $plan) { $snapshots.Add((Get-RegistrationSnapshot -ProductPath $item.Instance.ProductPath)) }
        if (Test-Path -LiteralPath $payloadFinal) { $previousPayload = $payloadFinal }

        $journal = [pscustomobject]@{
            id              = $transactionId
            stage           = 'prepare'
            startedAt       = (Get-Date -Format 'o')
            version         = $Setup.releaseVersion
            payloadFinal    = $payloadFinal
            previousPayload = $previousPayload
            backupPath      = $null
            snapshots       = $snapshots.ToArray()
            stateBefore     = $stateBefore
            rollback        = 'pending'
            rollbackDetail  = $null
        }
        Write-Journal -StateRoot $StateRoot -Journal $journal

        # 4. 暂存负载
        $payloadStage = $payloadFinal + '.stage-' + $transactionId
        Copy-BundleToPayload -Source $bundleInfo.Bundle -Destination $payloadStage
        $staged = Get-BundleInfo -Bundle $payloadStage
        if ($staged.Version -ne $Setup.releaseVersion) { throw '暂存目录校验失败：版本不一致。' }
        Write-Info -Stage 'COPY' ('负载已暂存：{0}' -f $payloadStage)

        # 5. 落位（旧负载先移到备份）
        $journal.stage = 'commit'
        Write-Journal -StateRoot $StateRoot -Journal $journal
        if (Test-Path -LiteralPath $payloadFinal) {
            $backup = Join-Path (Get-BackupRoot -StateRoot $StateRoot) ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $transactionId)
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            # Move-Item 到已存在的目录会把源目录搬进去，因此显式给出目标子路径，
            # 否则备份里会多出一层，回滚时按 journal 记录的路径找不到东西。
            $backupPayload = Join-Path $backup (Split-Path -Leaf $payloadFinal)
            Move-Item -LiteralPath $payloadFinal -Destination $backupPayload
            $journal.backupPath = $backupPayload
            Write-Journal -StateRoot $StateRoot -Journal $journal
            Write-Info -Stage 'BACKUP' ('旧负载已备份：{0}' -f $backupPayload)
        }
        Move-Item -LiteralPath $payloadStage -Destination $payloadFinal
        $payloadStage = $null
        Invoke-FaultInjection -Point 'commit'

        # 6. 注册每个实例
        $trusted = Get-OwnedDirectories -PayloadDir $payloadFinal
        $loader = Join-Path $payloadFinal 'Contents\Win64\CadMath03.dll'
        foreach ($item in $plan) {
            $registration = Set-InstanceRegistration -Instance $item.Instance -Loader $loader -TrustedDirs $trusted
            if (-not (Test-InstanceRegistered -Instance $item.Instance -Loader $loader)) {
                throw ('注册校验失败：{0}' -f $item.Instance.Label)
            }
            Write-Info -Stage 'REGISTER' ('已注册 {0}（更新 {1} 个配置的 TRUSTEDPATHS）' -f $item.Instance.Label, $registration.ProfilesUpdated)
        }
        Invoke-FaultInjection -Point 'register'

        # 7. 记录状态
        $entries = New-Object System.Collections.Generic.List[object]
        if ($stateBefore -ne $null -and $stateBefore.instances -ne $null) {
            foreach ($existing in @($stateBefore.instances)) {
                $stillMatches = $false
                foreach ($item in $plan) { if ($item.Instance.Id -eq $existing.instanceId) { $stillMatches = $true } }
                if (-not $stillMatches) { $entries.Add($existing) }
            }
        }
        foreach ($item in $plan) {
            $entries.Add([pscustomobject]@{
                instanceId = $item.Instance.Id
                adapterId  = $item.Adapter.id
                label      = $item.Instance.Label
                loader     = $loader
                installedAt = (Get-Date -Format 'o')
            })
        }
        $state = [pscustomobject]@{
            schemaVersion    = 1
            installedVersion = $Setup.releaseVersion
            payloadPath      = $payloadFinal
            instances        = $entries.ToArray()
        }
        Save-InstallState -StateRoot $StateRoot -State $state
        Invoke-FaultInjection -Point 'state'
        $journal.stage = 'done'
        $journal.rollback = 'not-needed'
        Write-Journal -StateRoot $StateRoot -Journal $journal
        Clear-Journal -StateRoot $StateRoot
        Write-Info -Stage 'DONE' ('安装完成：{0}，{1} 个实例' -f $Setup.releaseVersion, $plan.Count)
        return [pscustomobject]@{
            Success  = $true
            Version  = $Setup.releaseVersion
            Payload  = $payloadFinal
            Loader   = $loader
            Instances = $plan.ToArray()
            Rollback = 'not-needed'
        }
    } catch {
        $failure = $_.Exception.Message
        Write-Err -Stage 'INSTALL' $failure
        $rollback = 'failed'
        $detail = ''
        if ($journal -ne $null) {
            Write-Info -Stage 'ROLLBACK' '开始回滚：恢复注册表快照与负载目录'
            $repair = Restore-TransactionState -Journal $journal -StateRoot $StateRoot
            if ($repair.Success) {
                $rollback = 'succeeded'
                $detail = '已恢复安装前的注册表与负载状态'
                Write-Info -Stage 'ROLLBACK' $detail
            } else {
                $detail = '回滚未完成：' + $repair.Detail + '（可重新运行本工具，选择 1 让它尝试恢复）'
                Write-Err -Stage 'ROLLBACK' $detail
            }
            $journal.stage = 'rolled-back'
            $journal.rollback = $rollback
            $journal.rollbackDetail = $detail
            try { Write-Journal -StateRoot $StateRoot -Journal $journal } catch { }
            # 回滚成功就没有"待恢复"的事务了；失败才留下记录，等下次启动时提示恢复。
            if ($rollback -eq 'succeeded') { try { Clear-Journal -StateRoot $StateRoot } catch { } }
        } else {
            $rollback = 'not-needed'
            $detail = '失败发生在写入系统之前'
        }
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        return [pscustomobject]@{
            Success  = $false
            Error    = $failure
            Rollback = $rollback
            Detail   = $detail
        }
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-FaultInjection {
    param([string]$Point)
    # 仅供自动化测试：CADMATH_SETUP_INJECT_FAILURE=commit|register|state 时在指定阶段强制失败。
    $wanted = $env:CADMATH_SETUP_INJECT_FAILURE
    if ([string]::IsNullOrWhiteSpace($wanted)) { return }
    if ($wanted -ne $Point) { return }
    throw ('已按要求在阶段 {0} 注入故障（测试用）。' -f $Point)
}

function Restore-TransactionState {
    param($Journal, [string]$StateRoot)
    # 把一次失败或中断的事务退回到 journal 记录的安装前状态。
    try {
        foreach ($snapshot in @($Journal.snapshots)) { Restore-RegistrationSnapshot -Snapshot $snapshot }
        if ($Journal.payloadFinal) {
            $final = [string]$Journal.payloadFinal
            if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Recurse -Force }
        }
        if ($Journal.previousPayload) {
            $previous = [string]$Journal.previousPayload
            $backup = [string]$Journal.backupPath
            if ($backup -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $previous)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $previous) -Force | Out-Null
                Move-Item -LiteralPath $backup -Destination $previous
            }
        }
        if ($Journal.stateBefore -ne $null) { Save-InstallState -StateRoot $StateRoot -State $Journal.stateBefore }
        # 完成回滚后清理该事务留下的备份（此时旧负载已经回到原地）。
        if ($Journal.backupPath) {
            $backupDir = Split-Path -Parent ([string]$Journal.backupPath)
            if ($backupDir -and (Test-Path -LiteralPath $backupDir) -and -not (Get-ChildItem -LiteralPath $backupDir -Force)) {
                Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        # 回滚必须验证：报告"成功"却什么都没恢复，比报告失败更糟。
        $problems = New-Object System.Collections.Generic.List[string]
        foreach ($snapshot in @($Journal.snapshots)) {
            if ($snapshot -eq $null) { continue }
            if ($snapshot.Existed -and -not (Test-Path -LiteralPath ([string]$snapshot.AppKey))) {
                $problems.Add(('注册项未恢复：{0}' -f $snapshot.AppKey))
            }
        }
        if ($Journal.previousPayload) {
            if (-not (Test-Path -LiteralPath ([string]$Journal.previousPayload))) {
                $problems.Add(('旧版本负载未恢复：{0}' -f $Journal.previousPayload))
            }
        }
        if ($problems.Count -gt 0) {
            return [pscustomobject]@{ Success = $false; Detail = ($problems -join '；') }
        }
        return [pscustomobject]@{ Success = $true; Detail = '' }
    } catch {
        return [pscustomobject]@{ Success = $false; Detail = $_.Exception.Message }
    }
}

function Move-LegacyBundle {
    param([Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)][string]$StateRoot)
    # 旧式安装（ApplicationPlugins 目录）不删除，只移到备份目录，便于用户回退。
    if (-not (Test-Path -LiteralPath $BundlePath)) { return [pscustomobject]@{ Moved = $false; Path = $null } }
    $target = Join-Path (Get-BackupRoot -StateRoot $StateRoot) ('legacy-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $destination = Join-Path $target (Split-Path -Leaf $BundlePath)
    Move-Item -LiteralPath $BundlePath -Destination $destination
    return [pscustomobject]@{ Moved = $true; Path = $destination }
}

function Restore-PendingTransaction {
    param([Parameter(Mandatory)][string]$StateRoot)
    $journal = Read-Journal -StateRoot $StateRoot
    if ($journal -eq $null) { return [pscustomobject]@{ Found = $false } }
    $repair = Restore-TransactionState -Journal $journal -StateRoot $StateRoot
    if ($repair.Success) {
        Clear-Journal -StateRoot $StateRoot
        Write-Info -Stage 'RECOVER' ('已恢复中断于阶段 {0} 的操作（事务 {1}）' -f $journal.stage, $journal.id)
    } else {
        Write-Err -Stage 'RECOVER' ('恢复失败：{0}' -f $repair.Detail)
    }
    return [pscustomobject]@{
        Found   = $true
        Success = $repair.Success
        Stage   = $journal.stage
        Version = $journal.version
        Detail  = $repair.Detail
    }
}

function Uninstall-CadMathInstances {
    param(
        [Parameter(Mandatory)]$Instances,
        [Parameter(Mandatory)][string]$StateRoot
    )
    $results = New-Object System.Collections.Generic.List[object]
    $state = Read-InstallState -StateRoot $StateRoot
    $payload = $state.payloadPath
    if ($payload -and -not (Test-Path -LiteralPath $payload)) { $payload = $null }
    $owned = @()
    if ($payload) { $owned = Get-OwnedDirectories -PayloadDir $payload }
    $remaining = New-Object System.Collections.Generic.List[object]
    foreach ($existing in @($state.instances)) {
        $selected = $false
        foreach ($instance in $Instances) { if ($instance.Id -eq $existing.instanceId) { $selected = $true } }
        if (-not $selected) { $remaining.Add($existing) }
    }
    foreach ($instance in $Instances) {
        try {
            $removal = Remove-InstanceRegistration -Instance $instance -OwnedDirs $owned
            $check = Get-RegistrationKey -ProductPath $instance.ProductPath
            $ok = -not (Test-Path -LiteralPath $check)
            $results.Add([pscustomobject]@{
                Instance = $instance.Label
                Id       = $instance.Id
                Success  = $ok
                Detail   = ('删除注册项={0}，恢复 TRUSTEDPATHS 的配置数={1}' -f $removal.RemovedKey, $removal.ProfilesUpdated)
            })
            Write-Info -Stage 'UNINSTALL' ('{0}：{1}' -f $instance.Label, $(if ($ok) { '已卸载' } else { '卸载校验失败' }))
        } catch {
            $results.Add([pscustomobject]@{ Instance = $instance.Label; Id = $instance.Id; Success = $false; Detail = $_.Exception.Message })
            Write-Err -Stage 'UNINSTALL' ('{0}：{1}' -f $instance.Label, $_.Exception.Message)
        }
    }
    $allOk = $true
    foreach ($r in $results) { if (-not $r.Success) { $allOk = $false } }
    if ($remaining.Count -eq 0 -and $payload) {
        try {
            Remove-Item -LiteralPath $payload -Recurse -Force
            Write-Info -Stage 'UNINSTALL' ('已删除负载目录：{0}' -f $payload)
        } catch {
            Write-Warn -Stage 'UNINSTALL' ('负载目录删除失败：{0}' -f $_.Exception.Message)
        }
    }
    $newState = [pscustomobject]@{
        schemaVersion    = 1
        installedVersion = $(if ($remaining.Count -eq 0) { $null } else { $state.installedVersion })
        payloadPath      = $(if ($remaining.Count -eq 0) { $null } else { $payload })
        instances        = $remaining.ToArray()
    }
    Save-InstallState -StateRoot $StateRoot -State $newState
    return [pscustomobject]@{ Success = $allOk; Results = $results.ToArray(); RemainingInstances = $remaining.Count }
}
