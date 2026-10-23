# CadMath 安装与更新工具（命令行）
# 启动只做本地检测，不联网；选择「检查更新」后才访问发布源。
[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$RegistryRoot = 'HKCU:\Software\Autodesk\AutoCAD',
    [string]$MachineRegistryRoot = 'HKLM:\SOFTWARE\Autodesk\AutoCAD',
    [string]$AppsRoot,
    [ValidateSet('registration', 'appplugins')]
    [string]$Mode = 'registration',
    [string]$FromZip,
    [string]$FromBundle,
    [string]$SetupJson,
    [string]$Install,
    [string]$Remove,
    [switch]$Check,
    [switch]$Doctor,
    [switch]$Json,
    [switch]$NoNetwork,
    [switch]$RemoveLegacyBundle,
    [switch]$Yes,
    [switch]$Quiet
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$ToolVersion = '0.4.5'
$toolRoot = Split-Path $PSScriptRoot -Parent
$toolRoot = Split-Path $toolRoot -Parent
# 用户有没有显式指定安装方式：没指定时，交互模式会问一次，默认按版本注册。
$ModeExplicit = $PSBoundParameters.ContainsKey('Mode')

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Logging.ps1')
. (Join-Path $PSScriptRoot 'lib\Environment.ps1')
. (Join-Path $PSScriptRoot 'lib\Manifest.ps1')
. (Join-Path $PSScriptRoot 'lib\Registry.ps1')
. (Join-Path $PSScriptRoot 'lib\Install.ps1')
. (Join-Path $PSScriptRoot 'lib\Release.ps1')

if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Get-DefaultStateRoot }
if ([string]::IsNullOrWhiteSpace($AppsRoot)) { $AppsRoot = Get-ApplicationsRoot }

$logger = New-OperationLogger -StateRoot $StateRoot -ToolVersion $ToolVersion
$logger.Quiet = [bool]$Quiet

function Show-Banner {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (' CadMath 安装与更新工具 v{0}' -f $ToolVersion) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
}

function Get-InstancePackageState {
    param($Instance, $Setup, [string]$Architecture)
    if ($Setup -eq $null) {
        return [pscustomobject]@{ Text = '适配器状态：未知（未找到 setup.json）'; Matched = $null; Reason = 'no-manifest' }
    }
    $match = Select-AdapterForInstance -Setup $Setup -Instance $Instance -Architecture $Architecture
    if ($match.Status -eq 'matched') {
        return [pscustomobject]@{ Text = ('适配器：{0}（{1}）' -f $match.Adapter.id, $match.Adapter.status); Matched = $match.Adapter; Reason = $null }
    }
    if ($match.Status -eq 'ambiguous') {
        return [pscustomobject]@{ Text = ('适配器：歧义 — {0}' -f $match.Error); Matched = $null; Reason = 'ambiguous' }
    }
    return [pscustomobject]@{ Text = ('适配器：无匹配（{0}）' -f (Get-RejectionSummary -Rejections $match.Rejections)); Matched = $null; Reason = 'no-match' }
}

function Get-PluginStateText {
    param($Instance)
    switch ($Instance.PluginState) {
        'none'     { return '未安装插件' }
        'registry' {
            $versionText = '版本未知'
            if ($Instance.PluginVersion) { $versionText = 'v' + $Instance.PluginVersion }
            if (-not $Instance.PluginPathOk) { return ('已注册但文件缺失（{0}）' -f $Instance.PluginLoader) }
            return ('已安装插件 {0}' -f $versionText)
        }
        'bundle'   { return '已安装插件（旧式 ApplicationPlugins 目录，全局生效）' }
        'both'     { return '已安装插件（注册表 + 旧式目录并存，建议清理其一）' }
        default    { return '未安装插件' }
    }
}

function Show-Detection {
    param($Scan, $Setup)
    Write-Host ''
    Write-Host '[环境检测]' -ForegroundColor White
    Write-Host ('  操作系统：{0}' -f $Scan.Os)
    Write-Host ('  AutoCAD 实例：检测完成，共发现 {0} 个' -f @($Scan.Instances).Count)
    $state = Read-InstallState -StateRoot $StateRoot
    if ($state.installedVersion) {
        $modeText = '按版本注册'
        if ($state.mode -eq 'appplugins') { $modeText = 'ApplicationPlugins（全局）' }
        Write-Host ('  本工具安装状态：已安装 v{0}（{1}，{2} 个实例受管）' -f $state.installedVersion, $modeText, @($state.instances).Count)
        if ($state.mode -eq 'appplugins' -and $state.bundlePath) {
            Write-Host ('    安装位置：{0}' -f $state.bundlePath)
        }
    } else {
        Write-Host '  本工具安装状态：未安装'
    }
    if ($Setup -ne $null) {
        Write-Host ('  适配器清单：已读取（发行版本 v{0}）' -f $Setup.releaseVersion)
    } else {
        Write-Host '  适配器清单：未找到 setup.json（只能查看，不能安装）'
    }
    if ($Scan.LegacyBundle.Present) {
        $health = '完整'
        if ($Scan.LegacyBundle.Health -eq 'broken') { $health = '已损坏' }
        Write-Host ('  旧式安装：发现 CadMath03.bundle（版本 {0}，{1}，全局生效）' -f $Scan.LegacyBundle.Version, $health) -ForegroundColor Yellow
    }
    Write-Host '  网络状态：尚未检测（选择更新时才检查）'
    Write-Host ''
    Write-Host '[检测结果]' -ForegroundColor White
    if (@($Scan.Instances).Count -eq 0) {
        Write-Host '  未检测到 AutoCAD 安装。' -ForegroundColor Yellow
    }
    foreach ($instance in @($Scan.Instances)) {
        $buildText = '构建未知'
        if ($instance.BuildKnown) { $buildText = '构建 ' + $instance.Build }
        $pluginState = Get-InstancePackageState -Instance $instance -Setup $Setup -Architecture $Scan.Architecture
        $location = $instance.AcadLocation
        if ([string]::IsNullOrWhiteSpace($location)) { $location = '安装路径未知' }
        Write-Host ('  - {0}（{1}，{2}）' -f $instance.Label, $instance.Release, $buildText)
        Write-Host ('      路径：{0}' -f $location)
        Write-Host ('      状态：{0}；{1}' -f (Get-PluginStateText -Instance $instance), $pluginState.Text)
    }
    Write-Host ''
}

function Get-LocalPackage {
    $bundle = $null
    $setup = $null
    if ($FromBundle) { $bundle = $FromBundle }
    if ($SetupJson) { $setup = $SetupJson }
    foreach ($candidate in @($toolRoot, $PSScriptRoot, (Get-Location).Path)) {
        if (-not $bundle) {
            $path = Join-Path $candidate 'CadMath03.bundle'
            if (Test-Path -LiteralPath $path) { $bundle = $path }
        }
        if (-not $setup) {
            $path = Join-Path $candidate 'setup.json'
            if (Test-Path -LiteralPath $path) { $setup = $path }
        }
    }
    $result = [pscustomobject]@{ Bundle = $bundle; SetupPath = $setup; Setup = $null }
    if ($setup) {
        try {
            $result.Setup = Read-SetupManifest -Path $setup
        } catch {
            Write-Warn -Stage 'SCAN' ('发行清单不可用：{0}' -f $_.Exception.Message)
        }
    }
    return $result
}

function Read-Choice {
    param([string]$Prompt = '请输入选项 [1-4]：')
    while ($true) {
        Write-Host ''
        Write-Host $Prompt -ForegroundColor Cyan -NoNewline
        $input = Read-Host
        if ($null -eq $input) { continue }
        $trimmed = $input.Trim()
        if ($trimmed -match '^[1-4]$') { return [int]$trimmed }
        Write-Warn -Stage 'MENU' ('输入无效：“{0}”，只接受 1、2、3、4。' -f $trimmed)
    }
}

function Read-InstanceSelection {
    param($Instances, [string]$Prompt = '请输入序号（可多选，如 1,2；a=全部）：')
    # 不能直接 @($Instances)：PS 5.1 对泛型 List 做数组子表达式会抛"参数类型不匹配"。
    $items = ConvertTo-ItemArray -Value $Instances
    while ($true) {
        Write-Host ''
        Write-Host $Prompt -ForegroundColor Cyan -NoNewline
        $input = Read-Host
        if ($null -eq $input) { continue }
        $trimmed = $input.Trim().ToLowerInvariant()
        if ($trimmed -eq 'a') { return $items }
        $selected = New-Object System.Collections.Generic.List[object]
        $valid = $true
        foreach ($piece in $trimmed.Split(',')) {
            $text = $piece.Trim()
            if ($text -eq '') { continue }
            if ($text -notmatch '^\d+$') { $valid = $false; break }
            $index = [int]$text
            if ($index -lt 1 -or $index -gt $items.Count) { $valid = $false; break }
            $item = $items[$index - 1]
            if (-not ($selected | Where-Object { $_.Id -eq $item.Id })) { $selected.Add($item) }
        }
        if (-not $valid -or $selected.Count -eq 0) {
            Write-Warn -Stage 'MENU' ('输入无效：“{0}”，请重新输入序号。' -f $trimmed)
            continue
        }
        return $selected.ToArray()
    }
}

function Confirm-Action {
    param([string]$Question)
    if ($Yes) { return $true }
    Write-Host ''
    Write-Host ($Question + ' [y/N]：') -ForegroundColor Yellow -NoNewline
    $answer = Read-Host
    if ($null -eq $answer) { return $false }
    return ($answer.Trim() -match '^(y|Y|yes|YES)$')
}

function Show-Plan {
    param($Plan, $Setup, [string]$PayloadDir)
    Write-Host ''
    Write-Host '[执行计划]' -ForegroundColor White
    foreach ($item in $Plan) {
        $adapter = $item.Adapter
        Write-Host ('  CAD：{0}（{1}）' -f $item.Instance.Label, $item.Instance.Id)
        Write-Host ('  适配器：{0}（状态 {1}）' -f $adapter.id, $adapter.status)
        Write-Host ('  包版本：{0}' -f $Setup.releaseVersion)
        Write-Host ('  安装位置：{0}' -f $PayloadDir)
        if ($item.Instance.PluginState -ne 'none') {
            Write-Host '  注意：该实例已有 CadMath 安装，将被覆盖（旧负载会先备份）' -ForegroundColor Yellow
        }
        Write-Host ''
    }
}

function Resolve-LegacyBundle {
    param($Scan)
    # 旧式安装放在 ApplicationPlugins 里，会被同一台机器上所有 CAD 版本扫描到。
    # 如果不清掉它，新的按版本注册就会和它同时生效（一次按键处理两遍）。
    $legacy = $Scan.LegacyBundle
    if (-not (Test-LegacyInstallPresent -Legacy $legacy)) { return $true }
    Write-Warn -Stage 'LEGACY' ('检测到旧式安装：{0}（版本 {1}，全局生效）。' -f $legacy.Path, $legacy.Version)
    Write-Warn -Stage 'LEGACY' '它会与按版本注册的新安装同时生效，导致同一次按键被处理两次。'
    $approved = $false
    if ($RemoveLegacyBundle) {
        $approved = $true
    } elseif (-not $Yes -and -not $Quiet) {
        $approved = Confirm-Action -Question '先把旧式安装移到备份目录（不删除）再继续？'
    }
    if (-not $approved) {
        Write-Err -Stage 'LEGACY' '已停止，未修改任何文件。请先移走旧式安装，或加 -RemoveLegacyBundle 让工具代劳。'
        return $false
    }
    $moved = Move-LegacyBundle -BundlePath $legacy.Path -StateRoot $StateRoot
    Write-Info -Stage 'LEGACY' ('旧式安装已移到：{0}' -f $moved.Path)
    return $true
}

function Select-InstallMode {
    Write-Host ''
    Write-Host '[安装方式]' -ForegroundColor White
    Write-Host '  1. 按版本注册（推荐）：每个 AutoCAD 版本单独注册，可单独卸载，不动 AutoCAD 全局设置。'
    Write-Host '  2. ApplicationPlugins：复制到 %APPDATA%\Autodesk\ApplicationPlugins，所有版本共享一份，'
    Write-Host '     和以前的手工安装方式一致；卸载时整体移除，无法只卸某一个版本。'
    while ($true) {
        Write-Host ''
        Write-Host '请选择安装方式 [1-2]（直接回车＝1）：' -ForegroundColor Cyan -NoNewline
        $answer = Read-Host
        if ($null -eq $answer) { continue }
        $trimmed = $answer.Trim()
        if ($trimmed -eq '' -or $trimmed -eq '1') { return 'registration' }
        if ($trimmed -eq '2') { return 'appplugins' }
        Write-Warn -Stage 'MENU' ('输入无效：“{0}”，只接受 1 或 2。' -f $trimmed)
    }
}

function Invoke-InstallGlobalFlow {
    param($Scan, $Package)
    if ($Package.Setup -eq $null -or $Package.Bundle -eq $null) {
        Write-Err -Stage 'INSTALL' '找不到本地安装包（setup.json / CadMath03.bundle）。'
        return
    }
    if (-not (Resolve-LegacyBundle -Scan $Scan)) { return }
    $usable = New-Object System.Collections.Generic.List[object]
    $blocked = New-Object System.Collections.Generic.List[string]
    foreach ($instance in @($Scan.Instances)) {
        $state = Get-InstancePackageState -Instance $instance -Setup $Package.Setup -Architecture $Scan.Architecture
        if ($state.Matched -ne $null) { $usable.Add($instance) }
        else { $blocked.Add(('{0}（{1}）{2}' -f $instance.Label, $instance.Release, $(if ($state.Text) { '：' + $state.Text } else { '' }))) }
    }
    if ($usable.Count -eq 0) {
        Write-Err -Stage 'INSTALL' ('没有任何实例拥有可用适配器，已停止，未修改任何文件。原因：' + ($blocked -join '；'))
        return
    }
    $target = Get-GlobalBundlePath
    Write-Host ''
    Write-Host '[安装计划]' -ForegroundColor White
    Write-Host ('  方式：ApplicationPlugins（全局，{0} 个版本共享）' -f $usable.Count)
    Write-Host ('  安装到：{0}' -f $target)
    Write-Host ('  版本：v{0}' -f $Package.Setup.releaseVersion)
    Write-Host ('  可用实例：{0}' -f (($usable | ForEach-Object { $_.Label }) -join '、'))
    Write-Host '  注册表：不改动（Autodesk 自动扫描该目录）'
    Write-Host '  已有同名目录时会先移到备份目录。'
    if (-not (Confirm-Action -Question '确认按上面的计划安装？')) {
        Write-Info -Stage 'INSTALL' '用户取消，未修改任何文件。'
        return
    }
    $result = Install-CadMathGlobalBundle -Setup $Package.Setup -SourcePath $Package.Bundle -StateRoot $StateRoot -AppsRoot $AppsRoot
    Write-Host ''
    if ($result.Success) {
        Write-Host ('安装成功：v{0} → {1}' -f $result.Version, $result.Path) -ForegroundColor Green
        if ($result.BackupPath) { Write-Host ('旧目录已备份：{0}' -f $result.BackupPath) }
        Write-Host '请重启 AutoCAD，在命令行输入 CM3STATUS 确认。' -ForegroundColor Yellow
    } else {
        Write-Host ('安装失败：{0}' -f $result.Error) -ForegroundColor Red
    }
}

function Invoke-UninstallGlobalFlow {
    param($Scan)
    $target = Get-GlobalBundlePath
    $state = Read-InstallState -StateRoot $StateRoot
    Write-Host ''
    Write-Host '[将删除的内容]' -ForegroundColor White
    Write-Host ('  - 目录：{0}' -f $target)
    Write-Host ('  - 版本：v{0}' -f $state.installedVersion)
    Write-Host '  - 注册表：不改动；只清理本插件加入的 TRUSTEDPATHS 条目'
    Write-Host '  保留：日志、备份、用户图纸与其它插件。'
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Warn -Stage 'UNINSTALL' ('目录不存在：{0}，可能已经卸载过。' -f $target)
    }
    if (-not (Confirm-Action -Question '确认卸载？')) {
        Write-Info -Stage 'UNINSTALL' '用户取消，未修改任何文件。'
        return
    }
    $result = Uninstall-CadMathGlobalBundle -StateRoot $StateRoot -AppsRoot $AppsRoot -Instances @($Scan.Instances)
    Write-Host ''
    if ($result.BackupPath) { Write-Host ('已移到备份：{0}' -f $result.BackupPath) -ForegroundColor Green }
    Write-Host '卸载完成。' -ForegroundColor Green
}


function Invoke-InstallFlow {
    param($Scan, $Package)
    # 安装方式：显式参数优先；交互模式没指定时问一次，默认按版本注册。
    $mode = $Mode
    if (-not $ModeExplicit -and -not $Yes -and -not $Quiet) { $mode = Select-InstallMode }
    if ($mode -eq 'appplugins') { Invoke-InstallGlobalFlow -Scan $Scan -Package $Package; return }
    $instances = @($Scan.Instances)
    if ($instances.Count -eq 0) {
        Write-Err -Stage 'INSTALL' '没有检测到 AutoCAD 实例，无法安装。'
        return
    }
    if (-not (Resolve-LegacyBundle -Scan $Scan)) { return }
    Write-Host '[安装] 选择目标 AutoCAD 实例' -ForegroundColor White
    $index = 0
    $eligible = New-Object System.Collections.Generic.List[object]
    $blocked = New-Object System.Collections.Generic.List[string]
    foreach ($instance in $instances) {
        $index++
        $state = Get-InstancePackageState -Instance $instance -Setup $Package.Setup -Architecture $Scan.Architecture
        Write-Host ('  {0}. {1}（{2}）— {3}；{4}' -f $index, $instance.Label, $instance.Release, (Get-PluginStateText -Instance $instance), $state.Text)
        if ($state.Matched -ne $null) { $eligible.Add($instance) }
        else { $blocked.Add(('{0}（{1}）{2}' -f $instance.Label, $instance.Release, $(if ($state.Text) { '：' + $state.Text } else { '' }))) }
    }
    if ($eligible.Count -eq 0) {
        Write-Err -Stage 'INSTALL' ('没有任何实例拥有可用适配器，已停止，未修改任何文件。原因：' + ($blocked -join '；'))
        return
    }
    $selected = Read-InstanceSelection -Instances $instances
    $usable = New-Object System.Collections.Generic.List[object]
    foreach ($instance in $selected) {
        $state = Get-InstancePackageState -Instance $instance -Setup $Package.Setup -Architecture $Scan.Architecture
        if ($state.Matched -eq $null) {
            Write-Warn -Stage 'INSTALL' ('{0} 没有可用适配器，已从本次安装中排除。' -f $instance.Label)
        } else { $usable.Add($instance) }
    }
    if ($usable.Count -eq 0) {
        Write-Err -Stage 'INSTALL' '所选实例都不可安装，已停止。'
        return
    }
    $payloadDir = Get-PayloadDir -StateRoot $StateRoot -Version $Package.Setup.releaseVersion
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($instance in $usable) {
        $state = Get-InstancePackageState -Instance $instance -Setup $Package.Setup -Architecture $Scan.Architecture
        $plan.Add([pscustomobject]@{ Instance = $instance; Adapter = $state.Matched })
    }
    Show-Plan -Plan $plan -Setup $Package.Setup -PayloadDir $payloadDir
    if (-not (Confirm-Action -Question '确认按上面的计划安装？')) {
        Write-Info -Stage 'INSTALL' '用户取消，未修改任何文件。'
        return
    }
    $result = Install-CadMathPackage -Setup $Package.Setup -SourcePath $Package.Bundle -Instances $plan -StateRoot $StateRoot -Architecture $Scan.Architecture
    if ($result.Success) {
        Write-Host ''
        Write-Host ('安装成功：v{0}，{1} 个实例。' -f $result.Version, @($result.Instances).Count) -ForegroundColor Green
        Write-Host '文件安装与注册校验已通过；宿主内加载尚未验证 —— 请启动 AutoCAD，在命令行输入 CM3STATUS 确认。' -ForegroundColor Yellow
    } else {
        Write-Host ''
        Write-Host ('安装失败：{0}' -f $result.Error) -ForegroundColor Red
        if ($result.Rollback -eq 'succeeded') {
            Write-Host ('回滚：已恢复安装前状态。{0}' -f $result.Detail) -ForegroundColor Green
        } elseif ($result.Rollback -eq 'not-needed') {
            Write-Host '回滚：不需要（失败发生在写入系统之前）。' -ForegroundColor Green
        } else {
            Write-Host ('回滚：未完成。{0} 请根据日志手工恢复。' -f $result.Detail) -ForegroundColor Red
        }
    }
}

function Invoke-UpdateFlow {
    param($Scan, $Package)
    if ($NoNetwork) {
        Write-Warn -Stage 'UPDATE' '已按参数禁用网络，取消本次更新检查。'
        return
    }
    Write-Info -Stage 'UPDATE' '开始检查更新（本次操作会访问发布源）'
    if (-not (Test-NetworkAvailable)) {
        Write-Err -Stage 'UPDATE' '没有网络连接。可以改用本地安装包：把发行 zip 解压后运行 CadMath-Setup.cmd（离线安装同样校验哈希）。'
        return
    }
    try {
        $release = Get-LatestRelease
        $assets = Get-ReleaseAssets -Release $release
    } catch {
        Write-Err -Stage 'UPDATE' $_.Exception.Message
        return
    }
    $work = Join-Path $env:TEMP ('cadmath-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $setupPath = Join-Path $work $assets.Setup.name
        $null = Save-RemoteFile -Uri $assets.Setup.browser_download_url -Destination $setupPath
        $setup = Read-SetupManifest -Path $setupPath
        $state = Read-InstallState -StateRoot $StateRoot
        Write-Info -Stage 'UPDATE' ('远端版本 v{0}，本机受管版本 v{1}' -f $setup.releaseVersion, $(if ($state.installedVersion) { $state.installedVersion } else { '无' }))
        if ((Compare-ProductVersion -Current $state.installedVersion -Remote $setup.releaseVersion) -ge 0) {
            Write-Host ''
            Write-Host ('已是最新版本（v{0}），未修改任何文件。' -f $state.installedVersion) -ForegroundColor Green
            return
        }
        $applicable = New-Object System.Collections.Generic.List[object]
        foreach ($instance in @($Scan.Instances)) {
            $match = Select-AdapterForInstance -Setup $setup -Instance $instance -Architecture $Scan.Architecture
            if ($match.Status -eq 'matched') { $applicable.Add($instance) }
        }
        if ($applicable.Count -eq 0) {
            Write-Host ''
            Write-Host ('有产品新版本 v{0}，但本机没有任何 CAD 实例可用它（适配器不匹配）。' -f $setup.releaseVersion) -ForegroundColor Yellow
            return
        }
        Write-Host ''
        Write-Host ('发现新版本 v{0}（当前 v{1}）' -f $setup.releaseVersion, $state.installedVersion) -ForegroundColor Green
        $notes = $assets.Notes
        if ($notes) {
            Write-Host '[更新说明（节选）]' -ForegroundColor White
            $lines = ($notes -split "`n") | Select-Object -First 12
            foreach ($line in $lines) { Write-Host ('  ' + $line.TrimEnd()) }
            Write-Host ''
        }
        Write-Host ('可用实例：{0}' -f (($applicable | ForEach-Object { $_.Label }) -join '、'))
        if (-not (Confirm-Action -Question '下载并安装这个更新？')) {
            Write-Info -Stage 'UPDATE' '用户拒绝更新，未修改任何文件。'
            return
        }
        $zipPath = Join-Path $work $assets.Zip.name
        Write-Info -Stage 'UPDATE' ('下载 {0}' -f $assets.Zip.name)
        $null = Save-RemoteFile -Uri ($assets.Zip.browser_download_url) -Destination $zipPath
        $result = Install-CadMathPackage -Setup $setup -SourcePath $zipPath -Instances $applicable -StateRoot $StateRoot -Architecture $Scan.Architecture -IsUpdate
        if ($result.Success) {
            Write-Host ('更新成功：v{0}。请重启 AutoCAD 后输入 CM3STATUS 确认。' -f $result.Version) -ForegroundColor Green
        } else {
            Write-Host ('更新失败：{0}' -f $result.Error) -ForegroundColor Red
            if ($result.Rollback -eq 'succeeded') { Write-Host '回滚：已恢复到更新前的版本。' -ForegroundColor Green }
            else { Write-Host ('回滚：未完成。{0}' -f $result.Detail) -ForegroundColor Red }
        }
    } catch {
        Write-Err -Stage 'UPDATE' $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-UninstallFlow {
    param($Scan)
    $installed = Read-InstallState -StateRoot $StateRoot
    if ($installed.mode -eq 'appplugins') { Invoke-UninstallGlobalFlow -Scan $Scan; return }
    $managed = New-Object System.Collections.Generic.List[object]
    foreach ($instance in @($Scan.Instances)) {
        if ($instance.PluginState -eq 'registry' -or $instance.PluginState -eq 'both') { $managed.Add($instance) }
    }
    if ($managed.Count -eq 0) {
        Write-Host '没有检测到本工具安装的 CadMath。' -ForegroundColor Yellow
        if ($Scan.LegacyBundle.Present) {
            Write-Host ('发现旧式安装目录：{0}（版本 {1}）' -f $Scan.LegacyBundle.Path, $Scan.LegacyBundle.Version) -ForegroundColor Yellow
            $approved = $false
            if ($RemoveLegacyBundle) { $approved = $true }
            elseif (-not $Yes -and -not $Quiet) { $approved = Confirm-Action -Question '把旧式安装移到备份目录（不删除）？' }
            if ($approved) {
                $moved = Move-LegacyBundle -BundlePath $Scan.LegacyBundle.Path -StateRoot $StateRoot
                Write-Info -Stage 'UNINSTALL' ('旧式安装已移到：{0}' -f $moved.Path)
            } else {
                Write-Host '保留了旧式安装；如需移除，可加 -RemoveLegacyBundle 重新运行。'
            }
        }
        return
    }
    Write-Host '[卸载] 已检测到 CadMath 的实例' -ForegroundColor White
    $index = 0
    foreach ($instance in $managed) {
        $index++
        Write-Host ('  {0}. {1}（{2}）— {3}' -f $index, $instance.Label, $instance.Release, (Get-PluginStateText -Instance $instance))
    }
    $selected = Read-InstanceSelection -Instances ($managed.ToArray()) -Prompt '请输入要卸载的序号（可多选，如 1,2；a=全部）：'
    $state = Read-InstallState -StateRoot $StateRoot
    Write-Host ''
    Write-Host '[将删除的内容]' -ForegroundColor White
    foreach ($instance in $selected) {
        Write-Host ('  - 注册项：{0}' -f (Get-RegistrationKey -ProductPath $instance.ProductPath))
        Write-Host ('  - 本工具加入的 TRUSTEDPATHS 条目（只删自己那两条）')
    }
    if ($state.payloadPath) { Write-Host ('  - 负载目录（仅当没有实例再用它时）：{0}' -f $state.payloadPath) }
    Write-Host '  保留：日志、备份、用户图纸与其它插件。'
    if (-not (Confirm-Action -Question '确认卸载？')) {
        Write-Info -Stage 'UNINSTALL' '用户取消，未修改任何文件。'
        return
    }
    $result = Uninstall-CadMathInstances -Instances $selected -StateRoot $StateRoot
    Write-Host ''
    foreach ($item in $result.Results) {
        $mark = '失败'
        if ($item.Success) { $mark = '成功' }
        Write-Host ('  {0}：{1}（{2}）' -f $item.Instance, $mark, $item.Detail)
    }
    if ($result.Success) { Write-Host '卸载完成。' -ForegroundColor Green }
    else { Write-Host '部分实例卸载失败，详见上面的逐项结果与日志。' -ForegroundColor Red }
    # 旧式安装不在注册表里，卸载按版本注册的实例不会碰到它，这里单独处理。
    $legacy = $Scan.LegacyBundle
    if ($legacy -ne $null -and $legacy.Present) {
        Write-Warn -Stage 'UNINSTALL' ('检测到旧式安装：{0}（版本 {1}，全局生效）。' -f $legacy.Path, $legacy.Version)
        $approved = $false
        if ($RemoveLegacyBundle) { $approved = $true }
        elseif (-not $Yes -and -not $Quiet) { $approved = Confirm-Action -Question '把旧式安装移到备份目录（不删除）？' }
        if ($approved) {
            $moved = Move-LegacyBundle -BundlePath $legacy.Path -StateRoot $StateRoot
            Write-Info -Stage 'UNINSTALL' ('旧式安装已移到：{0}' -f $moved.Path)
        } else {
            Write-Info -Stage 'UNINSTALL' '保留了旧式安装；如需移除，可加 -RemoveLegacyBundle 重新运行。'
        }
    }
}

function Show-PendingTransaction {
    param([switch]$Interactive)
    $journal = Read-Journal -StateRoot $StateRoot
    if ($journal -eq $null) { return $false }
    $stage = [string]$journal.stage
    Write-Host ''
    Write-Warn -Stage 'RECOVER' ('检测到未完成的安装事务（{0}，阶段 {1}，开始于 {2}）。' -f $journal.id, $stage, $journal.startedAt)
    if (-not $Interactive) {
        Write-Warn -Stage 'RECOVER' ('当前为非交互模式，已保留事务记录：{0}；重新运行交互模式即可选择恢复。' -f (Get-JournalFile -StateRoot $StateRoot))
        return $false
    }
    if (-not (Confirm-Action -Question '尝试回滚这个未完成的事务？')) {
        Write-Warn -Stage 'RECOVER' ('保留事务记录：{0}' -f (Get-JournalFile -StateRoot $StateRoot))
        return $false
    }
    $result = Restore-PendingTransaction -StateRoot $StateRoot
    if ($result.Success) {
        Write-Host '未完成事务已回滚到事务开始前的状态。' -ForegroundColor Green
        return $true
    }
    Write-Err -Stage 'RECOVER' ('回滚未完成事务失败：{0}' -f $result.Detail)
    return $false
}

function Get-Summary {
    param($Scan)
    $state = Read-InstallState -StateRoot $StateRoot
    return [pscustomobject]@{
        ToolVersion      = $ToolVersion
        Os               = $Scan.Os
        Architecture     = $Scan.Architecture
        CadInstances     = @($Scan.Instances | ForEach-Object { [pscustomobject]@{ id = $_.Id; label = $_.Label; release = $_.Release; build = $_.Build; buildKnown = $_.BuildKnown; pluginState = $_.PluginState; pluginVersion = $_.PluginVersion; location = $_.AcadLocation } })
        InstalledVersion = $state.installedVersion
        InstalledMode    = $state.mode
        InstalledPath    = $(if ($state.mode -eq 'appplugins') { $state.bundlePath } else { $state.payloadPath })
        InstalledCount   = @($state.instances).Count
        LegacyBundle     = $Scan.LegacyBundle
        LogPath          = (Get-LogPath)
    }
}

# 每次操作完重新扫描一次：否则菜单里会拿着"操作前的快照"继续判断，
# 刚卸载掉的旧式安装仍会被当成还在，刚装上的版本也不会显示出来。
function Update-Environment {
    param($Package)
    $fresh = Invoke-EnvironmentScan -RegistryRoot $RegistryRoot -MachineRegistryRoot $MachineRegistryRoot -AppsRoot $AppsRoot -StateRoot $StateRoot
    Write-Host ''
    Write-Host '[检测结果已刷新]' -ForegroundColor White
    Show-Detection -Scan $fresh -Setup $Package.Setup
    return $fresh
}

# ---------------------------------------------------------------- 主流程
Show-Banner
Write-Info -Stage 'START' ('程序启动，工具版本 {0}' -f $ToolVersion)
Write-Info -Stage 'SCAN' '开始扫描本地环境（不联网）'
$scan = Invoke-EnvironmentScan -RegistryRoot $RegistryRoot -MachineRegistryRoot $MachineRegistryRoot -AppsRoot $AppsRoot -StateRoot $StateRoot
Write-Info -Stage 'SCAN' ('已发现 {0} 个 CAD 实例' -f @($scan.Instances).Count)
Write-Info -Stage 'SCAN' '本地环境扫描完成'
Write-Info -Stage 'SCAN' '未执行网络请求'

$package = Get-LocalPackage
Show-Detection -Scan $scan -Setup $package.Setup
$nonInteractive = ($Doctor -or $Json -or $Check -or $Install -or $Remove)
$recovered = Show-PendingTransaction -Interactive:(-not $nonInteractive)
if ($recovered) {
    $scan = Invoke-EnvironmentScan -RegistryRoot $RegistryRoot -MachineRegistryRoot $MachineRegistryRoot -AppsRoot $AppsRoot -StateRoot $StateRoot
    Show-Detection -Scan $scan -Setup $package.Setup
}

if ($Doctor -or $Json) {
    $summary = Get-Summary -Scan $scan
    if ($Json) { $summary | ConvertTo-Json -Depth 6 } else { $summary | Format-List }
    Write-Info -Stage 'EXIT' '只做检测，未修改系统'
    exit 0
}

# 非交互路径
$didAction = $false
if ($Check) {
    Write-Info -Stage 'EXIT' '仅检测模式结束'
    exit 0
}
if ($Install) {
    $didAction = $true
    if ($package.Setup -eq $null -or $package.Bundle -eq $null) { Write-Err -Stage 'INSTALL' '找不到本地安装包（setup.json / CadMath03.bundle）。'; exit 3 }
    if ($Mode -eq 'appplugins') {
        if (-not (Resolve-LegacyBundle -Scan $scan)) { exit 3 }
        $global = Install-CadMathGlobalBundle -Setup $package.Setup -SourcePath $package.Bundle -StateRoot $StateRoot -AppsRoot $AppsRoot
        if ($global.Success) { Write-Info -Stage 'EXIT' ('安装成功 v{0}（ApplicationPlugins）' -f $global.Version); exit 0 }
        Write-Err -Stage 'EXIT' ('安装失败：{0}' -f $global.Error); exit 3
    }
    $ids = $Install.Split(',')
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($id in $ids) {
        $found = @($scan.Instances | Where-Object { $_.Id -eq $id.Trim() })
        if ($found.Count -eq 0) { Write-Err -Stage 'INSTALL' ('找不到实例：{0}' -f $id); exit 2 }
        $targets.Add($found[0])
    }
    $didAction = $true
    if (-not (Resolve-LegacyBundle -Scan $scan)) { exit 3 }
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($instance in $targets) {
        $state = Get-InstancePackageState -Instance $instance -Setup $package.Setup -Architecture $scan.Architecture
        if ($state.Matched -eq $null) { Write-Err -Stage 'INSTALL' ('{0} 没有可用适配器。' -f $instance.Label); exit 3 }
        $plan.Add([pscustomobject]@{ Instance = $instance; Adapter = $state.Matched })
    }
    $result = Install-CadMathPackage -Setup $package.Setup -SourcePath $package.Bundle -Instances $plan -StateRoot $StateRoot -Architecture $scan.Architecture
    if ($result.Success) { Write-Info -Stage 'EXIT' ('安装成功 v{0}' -f $result.Version); exit 0 }
    Write-Err -Stage 'EXIT' ('安装失败：{0}' -f $result.Error); exit 3
}
if ($Remove) {
    $installedState = Read-InstallState -StateRoot $StateRoot
    if ($installedState.mode -eq 'appplugins') {
        $global = Uninstall-CadMathGlobalBundle -StateRoot $StateRoot -AppsRoot $AppsRoot -Instances @($scan.Instances)
        Write-Info -Stage 'EXIT' ('卸载完成（ApplicationPlugins，备份：{0}）' -f $global.BackupPath)
        exit 0
    }
    $ids = $Remove.Split(',')
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($id in $ids) {
        $found = @($scan.Instances | Where-Object { $_.Id -eq $id.Trim() })
        if ($found.Count -eq 0) { Write-Err -Stage 'UNINSTALL' ('找不到实例：{0}' -f $id); exit 2 }
        $targets.Add($found[0])
    }
    $result = Uninstall-CadMathInstances -Instances $targets.ToArray() -StateRoot $StateRoot
    if ($result.Success) { Write-Info -Stage 'EXIT' '卸载完成'; exit 0 }
    Write-Err -Stage 'EXIT' '卸载未全部成功'; exit 4
}

# 交互菜单
Write-Host '[运行日志]' -ForegroundColor White
Write-Info -Stage 'MENU' '等待用户选择'
try {
    while ($true) {
        Write-Host ''
        Write-Host '请选择操作：' -ForegroundColor White
        Write-Host '  1. 安装插件'
        Write-Host '  2. 检查是否有最新版本，有就安装'
        Write-Host '  3. 卸载该插件'
        Write-Host '  4. 退出'
        $choice = Read-Choice
        switch ($choice) {
            1 { Invoke-InstallFlow -Scan $scan -Package $package; $didAction = $true; $scan = Update-Environment -Package $package }
            2 { Invoke-UpdateFlow -Scan $scan -Package $package; $didAction = $true; $scan = Update-Environment -Package $package }
            3 { Invoke-UninstallFlow -Scan $scan; $didAction = $true; $scan = Update-Environment -Package $package }
            4 {
                Write-Info -Stage 'EXIT' '用户选择退出'
                if ($didAction) {
                    $summary = Get-Summary -Scan $scan
                    Write-Host ''
                    Write-Host '[本次会话摘要]' -ForegroundColor White
                    Write-Host ('  当前安装版本：{0}' -f $(if ($summary.InstalledVersion) { 'v' + $summary.InstalledVersion } else { '未安装' }))
                    Write-Host ('  受管实例数：{0}' -f $summary.InstalledCount)
                }
                Write-Host ('日志：{0}' -f (Get-LogPath)) -ForegroundColor Gray
                exit 0
            }
        }
    }
} catch {
    Write-Err -Stage 'FATAL' $_.Exception.Message
    Write-Err -Stage 'FATAL' ('异常类型：' + $_.Exception.GetType().FullName)
    if ($_.InvocationInfo) { Write-Err -Stage 'FATAL' ($_.InvocationInfo.PositionMessage) }
    Write-Host ('日志：{0}' -f (Get-LogPath)) -ForegroundColor Gray
    exit 1
}
