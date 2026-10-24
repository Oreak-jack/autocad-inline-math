# CadMath 安装工具 · 安装 / 更新 / 卸载（含事务与回滚）
Set-StrictMode -Version 2

# ApplicationPlugins 全局模式下会部署的 bundle 名字（顺序即部署顺序）。
# 每份 bundle 只承载一个 CLR 代 / 一个 SDK 编译锚，见 docs/VERSION-MATRIX.md。
$script:CadMathBundleNames = @('CadMath03.bundle', 'CadMath03-2025.bundle', 'CadMath03-2024.bundle', 'CadMath03-2020.bundle')

function Get-StateFile { param([string]$StateRoot) return (Join-Path $StateRoot 'state.json') }
function Get-JournalFile { param([string]$StateRoot) return (Join-Path $StateRoot 'pending.json') }
function Get-PayloadRoot { param([string]$StateRoot) return (Join-Path $StateRoot 'payload') }
function Get-PayloadDir { param([string]$StateRoot, [string]$Version) return (Join-Path (Get-PayloadRoot -StateRoot $StateRoot) $Version) }
function Get-BackupRoot { param([string]$StateRoot) return (Join-Path $StateRoot 'backups') }

function Read-InstallState {
    param([string]$StateRoot)
    $path = Get-StateFile -StateRoot $StateRoot
    $state = $null
    if (Test-Path -LiteralPath $path) {
        $state = Read-JsonFile -Path $path
    }
    if ($state -eq $null) {
        $state = [pscustomobject]@{ schemaVersion = 1; installedVersion = $null; payloadPath = $null; instances = @() }
    }
    # 旧版 state.json 没有 mode/bundlePath，补齐后再用，否则 StrictMode 下访问会抛"属性不存在"。
    $names = @($state.PSObject.Properties.Name)
    if ($names -notcontains 'mode') {
        $state | Add-Member -MemberType NoteProperty -Name mode -Value 'registration'
    }
    if ($names -notcontains 'bundlePath') {
        $state | Add-Member -MemberType NoteProperty -Name bundlePath -Value $null
    }
    if ($names -notcontains 'instances') {
        $state | Add-Member -MemberType NoteProperty -Name instances -Value @()
    }
    if ($names -notcontains 'bundlePaths') {
        $state | Add-Member -MemberType NoteProperty -Name bundlePaths -Value @()
    }
    if ($state.mode -ne 'appplugins') { $state.mode = 'registration' }
    return $state
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
    param([string]$PackageRoot, $Files)
    if ($Files -eq $null -or @($Files).Count -eq 0) {
        Write-Warn -Stage 'VERIFY' '发行清单没有 files 清单，跳过逐文件校验。'
        return
    }
    $root = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
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
    # 复制会连 "来自网络" 标记一起带过来，必须抹掉，否则 .NET Framework 拒绝加载（0x80131515）。
    $cleared = Clear-NetworkMark -Path $Destination
    if ($cleared -gt 0) {
        Write-Info -Stage 'UNBLOCK' ('已解除 {0} 个文件的"来自网络"标记（否则 .NET Framework 会拒绝加载）' -f $cleared)
    }
}

function Get-OwnedDirectories {
    # 一个负载目录里可能有多个宿主（Win64 给 2025/2026，Win64-2024 给 2021–2024，Win64-2020 给 2020），
    # 只要目录存在，就把宿主目录与它的 Adapters 子目录都登记到 TRUSTEDPATHS，卸载时再精确移除。
    param([string]$PayloadDir)
    $result = New-Object System.Collections.Generic.List[string]
    $contents = Join-Path $PayloadDir 'Contents'
    if (-not (Test-Path -LiteralPath $contents)) { return $result.ToArray() }

    foreach ($hostDir in @(Get-ChildItem -LiteralPath $contents -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Win64*' } | Sort-Object Name)) {
        $result.Add($hostDir.FullName)
        $adapters = Join-Path $hostDir.FullName 'Adapters'
        if (Test-Path -LiteralPath $adapters) { $result.Add($adapters) }
    }
    return $result.ToArray()
}

function Get-RemovableDirectories {
    # 卸载时要清理的 TRUSTEDPATHS 条目：本次安装加入的条目 + 0.3.x 用 ApplicationPlugins 时注册的条目
    # （升级/卸载后那些目录已经不存在，但用户配置里还留着无效路径）。
    param([string]$PayloadDir)
    $result = New-Object System.Collections.Generic.List[string]
    if ($PayloadDir) {
        foreach ($dir in (Get-OwnedDirectories -PayloadDir $PayloadDir)) { $result.Add($dir) }
    }
    foreach ($bundleName in $script:CadMathBundleNames) {
        $bundleDir = Join-Path (Get-ApplicationsRoot) $bundleName
        foreach ($hostDir in @(Get-ChildItem -LiteralPath (Join-Path $bundleDir 'Contents') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Win64*' } | Sort-Object Name)) {
            $result.Add($hostDir.FullName)
            $adapters = Join-Path $hostDir.FullName 'Adapters'
            if (Test-Path -LiteralPath $adapters) { $result.Add($adapters) }
        }
        # 0.3.x 时代恒为 Win64，即使目录已不存在也要把这两条历史路径登记进来，才能从 TRUSTEDPATHS 里清掉。
        $legacyHost = Join-Path $bundleDir 'Contents\Win64'
        $result.Add($legacyHost)
        $result.Add((Join-Path $legacyHost 'Adapters'))
    }
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
        [switch]$IsUpdate,
        [switch]$AllowExperimental
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
            $zipField = Get-SetupField -Setup $Setup -Name 'zip'
            if (-not $expectedZip -and $zipField) {
                $expectedZip = [string](Get-SetupField -Setup $zipField -Name 'sha256')
            }
            if ($expectedZip) {
                Write-Info -Stage 'VERIFY' ('校验安装包 SHA-256：{0}' -f (Split-Path $SourcePath -Leaf))
                $null = Test-FileSha256 -Path $SourcePath -Expected $expectedZip
                Write-Info -Stage 'VERIFY' '安装包 SHA-256 校验通过'
            } else {
                Write-Warn -Stage 'VERIFY' '本次没有拿到安装包的校验值，改为逐个文件校验。'
            }
            Write-Info -Stage 'EXTRACT' ('解压安装包：{0}' -f (Split-Path $SourcePath -Leaf))
        $bundleSource = Resolve-BundleFromArchive -Zip $SourcePath -WorkRoot $work
        }
        $bundleInfo = Get-BundleInfo -Bundle $bundleSource
        Write-Info -Stage 'VERIFY' ('逐文件校验 {0} 个文件…' -f @($Setup.files).Count)
        Test-BundleFiles -PackageRoot (Split-Path -Parent $bundleInfo.Bundle) -Files $Setup.files
        if ($bundleInfo.Version -ne $Setup.releaseVersion) {
            throw ('包版本 {0} 与发行清单 {1} 不一致。' -f $bundleInfo.Version, $Setup.releaseVersion)
        }
        $runtime = Read-RuntimeManifest -Path $bundleInfo.Config
        Write-Info -Stage 'VERIFY' ('包校验通过：{0} {1}，运行时清单 {2} 个适配器' -f $bundleInfo.Name, $bundleInfo.Version, @($runtime.adapters).Count)

        # 2. 逐实例匹配
        foreach ($instance in $targets) {
            $match = Select-AdapterForInstance -Setup $Setup -Instance $instance -Architecture $Architecture -AllowExperimental:$AllowExperimental
            if ($match.Status -ne 'matched') {
                throw ('{0}：{1}' -f $instance.Label, $(if ($match.Status -eq 'ambiguous') { $match.Error } else { '没有可用适配器（' + (Get-RejectionSummary -Rejections $match.Rejections) + '）' }))
            }

            # 入口 DLL 必须按实例的 CAD 版本决定：2024 用 .NET Framework 那份，2025/2026 用 .NET 8 那份。
            # 清单没有 hosts（0.4.1 及更早的包）时退回旧行为。
            $entry = $null
            if ($Setup.PSObject.Properties['hosts'] -and $Setup.hosts -ne $null) {
                $hostInfo = Get-HostForSeries -Setup $Setup -Series $instance.Series
                if ($hostInfo -eq $null) {
                    throw ('{0}：发行包没有为 {1} 提供宿主。' -f $instance.Label, $instance.Series)
                }
                $entry = ([string]$hostInfo.entry) -replace '/', '\'
            } else {
                $entry = $script:EntryAssembly
            }

            $plan.Add([pscustomobject]@{ Instance = $instance; Adapter = $match.Adapter; Entry = $entry })
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

        # 6. 注册每个实例（每个实例的 LOADER 指向自己那一代宿主的 CAD 程序集）
        $trusted = Get-OwnedDirectories -PayloadDir $payloadFinal
        $firstLoader = $null
        foreach ($item in $plan) {
            $loader = Join-Path $payloadFinal $item.Entry
            if (-not (Test-Path -LiteralPath $loader)) {
                throw ('负载里缺少 {0} 的宿主程序集：{1}' -f $item.Instance.Label, $item.Entry)
            }
            $registration = Set-InstanceRegistration -Instance $item.Instance -Loader $loader -TrustedDirs $trusted
            if (-not (Test-InstanceRegistered -Instance $item.Instance -Loader $loader)) {
                throw ('注册校验失败：{0}' -f $item.Instance.Label)
            }
            if (-not $firstLoader) { $firstLoader = $loader }
            Write-Info -Stage 'REGISTER' ('已注册 {0}（{1}；更新 {2} 个配置的 TRUSTEDPATHS）' -f $item.Instance.Label, $item.Entry, $registration.ProfilesUpdated)
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
                instanceId  = $item.Instance.Id
                adapterId   = $item.Adapter.id
                label       = $item.Instance.Label
                entry       = $item.Entry
                loader      = (Join-Path $payloadFinal $item.Entry)
                installedAt = (Get-Date -Format 'o')
            })
        }
        $state = [pscustomobject]@{
            schemaVersion    = 1
            mode             = 'registration'
            installedVersion = $Setup.releaseVersion
            payloadPath      = $payloadFinal
            bundlePath       = $null
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
            Loader   = $firstLoader
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
    $owned = @(Get-RemovableDirectories -PayloadDir $payload)
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
        mode             = 'registration'
        installedVersion = $(if ($remaining.Count -eq 0) { $null } else { $state.installedVersion })
        payloadPath      = $(if ($remaining.Count -eq 0) { $null } else { $payload })
        bundlePath       = $null
        instances        = $remaining.ToArray()
    }
    Save-InstallState -StateRoot $StateRoot -State $newState
    return [pscustomobject]@{ Success = $allOk; Results = $results.ToArray(); RemainingInstances = $remaining.Count }
}

# ---------------------------------------------------------------- 全局模式（ApplicationPlugins）
# 另一种合法装法：把整个 bundle 放进 %APPDATA%\Autodesk\ApplicationPlugins，
# 由 AutoCAD 自己扫描加载。所有 CAD 版本共享同一份，不能按实例卸载 —— 换来的是
# 注册表零改动，跟 0.3.x 的老做法完全一致。

function Get-GlobalBundlePaths {
    # 全局模式可能装四份：CadMath03.bundle（2026）、CadMath03-2025.bundle（2025）、
    # CadMath03-2024.bundle（2021–2024）与 CadMath03-2020.bundle（2020）。四者互不干扰。
    param([string]$AppsRoot)
    $root = $AppsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = Get-ApplicationsRoot }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($name in $script:CadMathBundleNames) {
        $list.Add([pscustomobject]@{ Name = $name; Path = (Join-Path $root $name) })
    }
    return $list.ToArray()
}

function Get-GlobalBundlePath {
    param([string]$AppsRoot)
    $root = $AppsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = Get-ApplicationsRoot }
    return (Join-Path $root 'CadMath03.bundle')
}

function Install-CadMathGlobalBundle {
    param(
        [Parameter(Mandatory)]$Setup,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$AppsRoot,
        [string]$ZipSha256
    )
    Assert-CadClosed
    $txid = [guid]::NewGuid().ToString('N')
    $work = Join-Path $StateRoot (Join-Path 'downloads' $txid)
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        # 1. 解析负载来源（目录或 zip）并校验完整性
        $bundleRoot = $SourcePath
        if ($SourcePath -like '*.zip') {
            $expectedZip = $ZipSha256
            $zipField = Get-SetupField -Setup $Setup -Name 'zip'
            if (-not $expectedZip -and $zipField) {
                $expectedZip = [string](Get-SetupField -Setup $zipField -Name 'sha256')
            }
            if ($expectedZip) {
                Write-Info -Stage 'VERIFY' ('校验安装包 SHA-256：{0}' -f (Split-Path $SourcePath -Leaf))
                $null = Test-FileSha256 -Path $SourcePath -Expected $expectedZip
                Write-Info -Stage 'VERIFY' '安装包 SHA-256 校验通过'
            }
            Write-Info -Stage 'EXTRACT' ('解压安装包：{0}' -f (Split-Path $SourcePath -Leaf))
            $bundleRoot = Resolve-BundleFromArchive -Zip $SourcePath -WorkRoot $work
        }
        $info = Get-BundleInfo -Bundle $bundleRoot
        if ($info.Version -ne [string]$Setup.releaseVersion) {
            throw ('安装包版本是 {0}，清单要求 {1}。' -f $info.Version, $Setup.releaseVersion)
        }
        Write-Info -Stage 'VERIFY' ('逐文件校验 {0} 个文件…' -f @($Setup.files).Count)
        $null = Test-BundleFiles -PackageRoot (Split-Path -Parent $bundleRoot) -Files $Setup.files
        Write-Info -Stage 'VERIFY' ('包校验通过：{0} {1}' -f $info.Name, $info.Version)

        $packageRoot = Split-Path -Parent $bundleRoot
        $parent = Split-Path -Parent (Get-GlobalBundlePath -AppsRoot $AppsRoot)
        New-Item -ItemType Directory -Path $parent -Force | Out-Null

        $installedPaths = New-Object System.Collections.Generic.List[string]
        $backupPath = $null
        foreach ($entry in (Get-GlobalBundlePaths -AppsRoot $AppsRoot)) {
            $source = Join-Path $packageRoot $entry.Name
            if (-not (Test-Path -LiteralPath $source)) {
                if ($entry.Name -ne 'CadMath03.bundle') { continue }
                throw ('安装包目录里没有 {0}。' -f $entry.Name)
            }
            if ($entry.Name -ne 'CadMath03.bundle') {
                # 2024 / 2020 那两份的 ProductCode 与主包不同，只做结构性检查：
                # 必须有 PackageContents.xml，且至少有一个 Contents\Win64*\CadMath03.dll 宿主体。
                if (-not (Test-Path -LiteralPath (Join-Path $source 'PackageContents.xml'))) {
                    throw ('安装包目录里缺少 {0}\PackageContents.xml。' -f $entry.Name)
                }
                $hostDlls = @(Get-ChildItem -LiteralPath (Join-Path $source 'Contents') -Recurse -File -Filter 'CadMath03.dll' -ErrorAction SilentlyContinue)
                if ($hostDlls.Count -eq 0) {
                    throw ('安装包目录里缺少 {0}\Contents\Win64*\CadMath03.dll。' -f $entry.Name)
                }
            }

            if (Test-Path -LiteralPath $entry.Path) {
                $backup = Join-Path (Get-BackupRoot -StateRoot $StateRoot) ('appplugins-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ($entry.Name -replace '\.bundle$', ''))
                New-Item -ItemType Directory -Path $backup -Force | Out-Null
                Move-Item -LiteralPath $entry.Path -Destination (Join-Path $backup $entry.Name)
                if (-not $backupPath) { $backupPath = $backup }
                Write-Info -Stage 'BACKUP' ('旧 {0} 已移到：{1}' -f $entry.Name, $backup)
            }

            Copy-Item -LiteralPath $source -Destination $entry.Path -Recurse -Force
            $cleared = Clear-NetworkMark -Path $entry.Path
            if ($cleared -gt 0) {
                Write-Info -Stage 'UNBLOCK' ('已解除 {0} 个文件的"来自网络"标记' -f $cleared)
            }
            if (-not (Test-Path -LiteralPath (Join-Path $entry.Path 'PackageContents.xml'))) {
                throw ('复制后的目录里没有 PackageContents.xml：{0}' -f $entry.Path)
            }
            $installedPaths.Add($entry.Path)
            Write-Info -Stage 'COPY' ('已复制 {0}' -f $entry.Path)
        }

        $state = [pscustomobject]@{
            schemaVersion    = 1
            mode             = 'appplugins'
            installedVersion = $info.Version
            payloadPath      = $null
            bundlePath       = $installedPaths[0]
            bundlePaths      = $installedPaths.ToArray()
            instances        = @()
        }
        Save-InstallState -StateRoot $StateRoot -State $state
        Write-Info -Stage 'DONE' ('已装到 ApplicationPlugins：{0}（版本 {1}，所有 CAD 版本共享）' -f ($installedPaths -join '、'), $info.Version)
        return [pscustomobject]@{ Success = $true; Version = $info.Version; Path = $installedPaths[0]; Paths = $installedPaths.ToArray(); BackupPath = $backupPath }
    } catch {
        Write-Err -Stage 'INSTALL' $_.Exception.Message
        return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; Path = (Get-GlobalBundlePath -AppsRoot $AppsRoot) }
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Uninstall-CadMathGlobalBundle {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$AppsRoot,
        $Instances
    )
    $owned = @(Get-RemovableDirectories -PayloadDir $null)
    $cleaned = New-Object System.Collections.Generic.List[string]
    foreach ($instance in (ConvertTo-ItemArray -Value $Instances)) {
        try {
            $null = Remove-InstanceRegistration -Instance $instance -OwnedDirs $owned
            $cleaned.Add($instance.Label)
        } catch {
            Write-Warn -Stage 'UNINSTALL' ('{0}：清理 TRUSTEDPATHS 失败 {1}' -f $instance.Label, $_.Exception.Message)
        }
    }
    $backupPath = $null
    $removed = New-Object System.Collections.Generic.List[string]
    $backup = Join-Path (Get-BackupRoot -StateRoot $StateRoot) ('appplugins-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    foreach ($entry in (Get-GlobalBundlePaths -AppsRoot $AppsRoot)) {
        if (-not (Test-Path -LiteralPath $entry.Path)) { continue }
        if (-not (Test-Path -LiteralPath $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }
        Move-Item -LiteralPath $entry.Path -Destination (Join-Path $backup $entry.Name)
        $removed.Add($entry.Path)
        $backupPath = $backup
    }
    $empty = [pscustomobject]@{
        schemaVersion    = 1
        mode             = 'registration'
        installedVersion = $null
        payloadPath      = $null
        bundlePath       = $null
        instances        = @()
    }
    Save-InstallState -StateRoot $StateRoot -State $empty
    if ($backupPath) {
        Write-Info -Stage 'UNINSTALL' ('已移除 ApplicationPlugins 里的插件，备份在：{0}' -f $backupPath)
    } else {
        Write-Info -Stage 'UNINSTALL' 'ApplicationPlugins 里没有找到 CadMath03.bundle，未删除任何插件文件。'
    }
    return [pscustomobject]@{ Success = $true; Removed = ($removed.Count -gt 0); RemovedPaths = $removed.ToArray(); BackupPath = $backupPath; Cleaned = $cleaned.ToArray() }
}
