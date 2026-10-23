# CadMath 命令行安装工具 · 自动化测试
# 全程隔离：状态目录用临时目录，注册表用 HKCU 下的假根，不触碰真实 CAD 安装。
[CmdletBinding()]
param(
    [string]$SetupJson,
    [string]$BundleDir,
    [string]$ZipPath
)

# 用 -File 调用时参数默认值里的 $PSScriptRoot 可能为空，这里显式兜底。
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PSScriptRoot = $scriptDir
if (-not $SetupJson) { $SetupJson = Join-Path $scriptDir '..\..\..\dist\setup.json' }
if (-not $BundleDir) { $BundleDir = Join-Path $scriptDir '..\..\..\dist\CadMath03.bundle' }
if (-not $ZipPath) { $ZipPath = Join-Path $scriptDir '..\..\..\dist\CadMath-InlineMath-0.4.1.zip' }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
# 自动化测试期间允许在 CAD 开着时继续（测试从不触碰运行中的 CAD；
# 最后一个用例会临时清掉这个变量，验证真实用户路径确实被拒绝）。
$env:CADMATH_SETUP_ALLOW_CAD_RUNNING = '1'

$libDir = Join-Path $PSScriptRoot '..\lib'
foreach ($name in 'Common', 'Logging', 'Environment', 'Manifest', 'Registry', 'Install', 'Release') {
    . (Join-Path $libDir ($name + '.ps1'))
}

$entry = Join-Path $PSScriptRoot '..\CadMath-Setup.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$root = Join-Path $env:TEMP ('cadmath-setup-test-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $root 'state'
$appsRoot = Join-Path $root 'apps'
$regBase = 'HKCU:\Software\CadMathSetupTest\' + [guid]::NewGuid().ToString('N')
$machineBase = 'HKCU:\Software\CadMathSetupTestMachine\' + [guid]::NewGuid().ToString('N')
# 扫描器接收的是"release 键的父目录"，机器信息接收的是"SOFTWARE\Autodesk\AutoCAD"。
$regRoot = Join-Path $regBase 'AutoCAD'
$machineRoot = Join-Path $machineBase 'SOFTWARE\Autodesk\AutoCAD'
$failures = New-Object System.Collections.Generic.List[string]
$passes = 0

function Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $ok = & $Test
        if ($ok) {
            $script:passes++
            Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
        } else {
            $script:failures.Add($Name)
            Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red
        }
    } catch {
        $script:failures.Add($Name + ' → ' + $_.Exception.Message)
        Write-Host ('  [FAIL] ' + $Name + ' → ' + $_.Exception.Message) -ForegroundColor Red
    }
}

function Expect-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -like $Pattern) { return $true }
        throw ('异常信息不匹配：' + $_.Exception.Message)
    }
    return $false
}

function New-TestBundle {
    param([string]$Destination, [string]$Version)
    Copy-Item -LiteralPath $BundleDir -Destination $Destination -Recurse -Force
    $xml = Join-Path $Destination 'PackageContents.xml'
    $text = [IO.File]::ReadAllText($xml, [Text.Encoding]::UTF8)
    $text = $text -replace 'AppVersion="[^"]+"', ('AppVersion="' + $Version + '"')
    [IO.File]::WriteAllText($xml, $text, (New-Object Text.UTF8Encoding($true)))
    # 让主程序集版本与 PackageContents 保持一致，模拟一个"更新的版本"。
    $info = Join-Path $Destination 'BUILD-INFO.txt'
    [IO.File]::WriteAllText($info, ('CadMath03 ' + $Version), (New-Object Text.UTF8Encoding($true)))
    return $Destination
}

try {
    Write-Host ''
    Write-Host '=== 环境准备' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $appsRoot -Force | Out-Null
    $logger = New-OperationLogger -StateRoot $stateRoot -ToolVersion 'test'
    $logger.Quiet = $true
    Write-Output ('  日志：' + (Get-LogPath))

    # 假注册表：一个 R25.1 实例（指向真实 AutoCAD 2026 目录，用来读构建号）+ 一个 R24.3 实例。
    $product25 = Join-Path $regRoot 'R25.1\ACAD-9101:804'
    $product24 = Join-Path $regRoot 'R24.3\ACAD-9010:409'
    New-Item -Path $product25 -Force | Out-Null
    New-Item -Path ($product25 + '\Profiles\<<未命名配置>>\Variables') -Force | Out-Null
    Set-ItemProperty -Path ($product25 + '\Profiles\<<未命名配置>>\Variables') -Name TRUSTEDPATHS -Value 'C:\Existing\Path'
    New-Item -Path $product24 -Force | Out-Null
    $machine25 = Join-Path $machineRoot 'R25.1\ACAD-9101:804'
    $machine24 = Join-Path $machineRoot 'R24.3\ACAD-9010:409'
    New-Item -Path $machine25 -Force | Out-Null
    New-Item -Path $machine24 -Force | Out-Null
    Set-ItemProperty -Path $machine25 -Name AcadLocation -Value 'D:\AutoCAD 2026\'
    Set-ItemProperty -Path $machine24 -Name AcadLocation -Value 'C:\Program Files\Autodesk\AutoCAD 2024\'
    Write-Output '  假注册表已建立'

    $scan = Invoke-EnvironmentScan -RegistryRoot $regRoot -MachineRegistryRoot $machineRoot -AppsRoot $appsRoot -StateRoot $stateRoot
    $setup = Read-SetupManifest -Path $SetupJson
    $instance25 = @($scan.Instances | Where-Object { $_.Release -eq 'R25.1' })[0]
    $instance24 = @($scan.Instances | Where-Object { $_.Release -eq 'R24.3' })[0]

    Write-Host ''
    Write-Host '=== 发行清单' -ForegroundColor Cyan
    Check '清单可读取，版本与适配器齐全' {
        $setup.product -eq 'CadMath' -and $setup.adapters.Count -ge 2 -and $setup.files.Count -ge 5
    }
    Check '清单拒绝未知状态' {
        $bad = Join-Path $root 'bad-status.json'
        $clone = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $clone.adapters[0].status = 'whatever'
        [IO.File]::WriteAllText($bad, ($clone | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($true)))
        Expect-Throws { Read-SetupManifest -Path $bad } '*不受支持*'
    }
    Check '清单拒绝重复适配器 id' {
        $bad = Join-Path $root 'dup-id.json'
        $clone = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $clone.adapters[1].id = $clone.adapters[0].id
        [IO.File]::WriteAllText($bad, ($clone | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($true)))
        Expect-Throws { Read-SetupManifest -Path $bad } '*重复*'
    }
    Check '清单拒绝未填好的 buildRange 占位值' {
        $bad = Join-Path $root 'placeholder.json'
        $clone = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $clone.adapters[0] | Add-Member -NotePropertyName buildRange -NotePropertyValue ([pscustomobject]@{ min = 'REPLACE_WITH_EVIDENCE'; max = 'REPLACE_WITH_EVIDENCE' }) -Force
        [IO.File]::WriteAllText($bad, ($clone | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($true)))
        Expect-Throws { Read-SetupManifest -Path $bad } '*占位*'
    }

    Write-Host ''
    Write-Host '=== 适配器匹配' -ForegroundColor Cyan
    Check '2026 实例匹配到 modern-r25' {
        $m = Select-AdapterForInstance -Setup $setup -Instance $instance25 -Architecture 'x64'
        $m.Status -eq 'matched' -and $m.Adapter.id -eq 'modern-r25'
    }
    Check '2024 实例被拒绝且给出原因' {
        $m = Select-AdapterForInstance -Setup $setup -Instance $instance24 -Architecture 'x64'
        $reasons = @($m.Rejections | ForEach-Object { $_.Reason })
        $m.Status -eq 'none' -and ($reasons -contains 'series-mismatch') -and ($reasons -contains 'status-planned')
    }
    Check '适配器声明了构建区间、但实例构建号未知时拒绝' {
        $rangeSetup = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $rangeSetup.adapters[0] | Add-Member -NotePropertyName buildRange -NotePropertyValue ([pscustomobject]@{ min = '25.1.50.0'; max = '25.1.55.0' }) -Force
        $ghost = [pscustomobject]@{ Id = 'x'; Series = 'R25.1'; Build = $null; BuildKnown = $false; Label = 'ghost' }
        $m = Select-AdapterForInstance -Setup $rangeSetup -Instance $ghost -Architecture 'x64'
        $reasons = @($m.Rejections | ForEach-Object { $_.Reason })
        $m.Status -eq 'none' -and ($reasons -contains 'build-unknown')
    }
    Check '支持区间之外的构建号被拒绝' {
        $rangeSetup = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $rangeSetup.adapters[0] | Add-Member -NotePropertyName buildRange -NotePropertyValue ([pscustomobject]@{ min = '25.1.50.0'; max = '25.1.55.0' }) -Force
        $instance = [pscustomobject]@{ Id = 'y'; Series = 'R25.1'; Build = '25.1.60.0'; BuildKnown = $true; Label = 'test' }
        $m = Select-AdapterForInstance -Setup $rangeSetup -Instance $instance -Architecture 'x64'
        $reasons = @($m.Rejections | ForEach-Object { $_.Reason })
        $m.Status -eq 'none' -and ($reasons -contains 'build-out-of-range')
    }
    Check '两个适配器同样匹配时报歧义' {
        $amb = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $twin = $amb.adapters[0] | Select-Object *
        $twin.id = 'modern-r25-copy'
        $amb.adapters += $twin
        $m = Select-AdapterForInstance -Setup $amb -Instance $instance25 -Architecture 'x64'
        $m.Status -eq 'ambiguous'
    }

    Write-Host ''
    Write-Host '=== 压缩包安全' -ForegroundColor Cyan
    Check '拒绝路径穿越的压缩包条目' {
        $evil = Join-Path $root 'evil.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::Open($evil, 'Create')
        try {
            $zipEntry = $archive.CreateEntry('../escape.txt')
            $writer = New-Object IO.StreamWriter($zipEntry.Open())
            $writer.Write('x'); $writer.Dispose()
        } finally { $archive.Dispose() }
        Expect-Throws { Expand-CadBundleArchive -Zip $evil -Destination (Join-Path $root 'evil-out') } '*越界*'
    }
    Check '正常压缩包能解出 PackageContents.xml' {
        if (-not (Test-Path $ZipPath)) { return $false }
        $out = Join-Path $root 'zip-out'
        $null = Expand-CadBundleArchive -Zip $ZipPath -Destination $out
        $resolved = Resolve-BundleFromArchive -Zip $ZipPath -WorkRoot (Join-Path $root 'zip-resolve')
        Test-Path (Join-Path $resolved 'PackageContents.xml')
    }

    Write-Host ''
    Write-Host '=== 命令行模式（子进程）' -ForegroundColor Cyan
    $cli = @{
        SetupJson = $SetupJson
        FromBundle = $BundleDir
        StateRoot = $stateRoot
        RegistryRoot = $regRoot
        MachineRegistryRoot = $machineRoot
        AppsRoot = $appsRoot
    }
    function Invoke-Cli {
        param([string[]]$Extra)
        $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entry) + $Extra +
            @('-SetupJson', $cli.SetupJson, '-FromBundle', $cli.FromBundle, '-StateRoot', $cli.StateRoot,
              '-RegistryRoot', $cli.RegistryRoot, '-MachineRegistryRoot', $cli.MachineRegistryRoot, '-AppsRoot', $cli.AppsRoot)
        $output = & $powershell @cliArgs 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    Check '-Json 输出结构化扫描结果且退出码 0' {
        $r = Invoke-Cli -Extra @('-Json')
        $start = $r.Output.IndexOf('{')
        $end = $r.Output.LastIndexOf('}')
        if ($start -lt 0 -or $end -le $start) { return $false }
        $parsed = $r.Output.Substring($start, $end - $start + 1) | ConvertFrom-Json
        $r.ExitCode -eq 0 -and @($parsed.CadInstances).Count -eq 2
    }
    Check '安装到 2026 实例成功，注册项与负载就位' {
        $r = Invoke-Cli -Extra @('-Install', 'R25.1\ACAD-9101:804', '-Yes')
        $key = Get-RegistrationKey -ProductPath $instance25.ProductPath
        if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $key)) {
            $dump = Join-Path $env:TEMP 'cm-install-fail.log'
            [IO.File]::WriteAllText($dump, $r.Output, (New-Object Text.UTF8Encoding($true)))
            throw ('退出码 {0}；完整输出见 {1}' -f $r.ExitCode, $dump)
        }
        $loader = (Get-ItemProperty -LiteralPath $key).LOADER
        (Test-Path -LiteralPath $loader)
    }
    Check 'TRUSTEDPATHS 保留原有路径并追加本产品目录' {
        $vars = $instance25.ProductPath + '\Profiles\<<未命名配置>>\Variables'
        $value = [string](Get-ItemProperty -LiteralPath $vars).TRUSTEDPATHS
        $value -like '*C:\Existing\Path*' -and $value -like '*payload*Win64*' -and $value -like '*Adapters*'
    }
    Check '重复安装（修复）仍然成功' {
        $r = Invoke-Cli -Extra @('-Install', 'R25.1\ACAD-9101:804', '-Yes')
        $r.ExitCode -eq 0
    }
    Check '给 2024 安装会被拒绝，退出码 3' {
        $r = Invoke-Cli -Extra @('-Install', 'R24.3\ACAD-9010:409', '-Yes')
        $r.ExitCode -eq 3 -and $r.Output -match '没有可用适配器'
    }
    Check '卸载 2026 实例成功并清理注册项' {
        $r = Invoke-Cli -Extra @('-Remove', 'R25.1\ACAD-9101:804', '-Yes')
        $key = Get-RegistrationKey -ProductPath $instance25.ProductPath
        $r.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $key)
    }
    Check '卸载后 TRUSTEDPATHS 恢复为原值' {
        $vars = $instance25.ProductPath + '\Profiles\<<未命名配置>>\Variables'
        if (-not (Test-Path -LiteralPath $vars)) { return $true }
        $value = [string](Get-ItemProperty -LiteralPath $vars).TRUSTEDPATHS
        $value -eq 'C:\Existing\Path'
    }

    Write-Host ''
    Write-Host '=== 事务与回滚' -ForegroundColor Cyan
    Check '更新中途失败会回滚到旧版本' {
        $r = Invoke-Cli -Extra @('-Install', 'R25.1\ACAD-9101:804', '-Yes')
        if ($r.ExitCode -ne 0) { return $false }
        $env:CADMATH_SETUP_INJECT_FAILURE = 'register'
        try { $failed = Invoke-Cli -Extra @('-Install', 'R25.1\ACAD-9101:804', '-Yes') } finally { $env:CADMATH_SETUP_INJECT_FAILURE = $null }
        $state = Read-InstallState -StateRoot $stateRoot
        $key = Get-RegistrationKey -ProductPath $instance25.ProductPath
        $loader = (Get-ItemProperty -LiteralPath $key).LOADER
        $failed.ExitCode -eq 3 -and $failed.Output -match '已恢复安装前的注册表与负载状态' -and
            $state.installedVersion -eq '0.4.1' -and (Test-Path -LiteralPath $loader) -and
            -not (Test-Path (Get-JournalFile -StateRoot $stateRoot))
    }
    Check '回滚失败时保留事务记录，重启后可恢复' {
        $payload = (Read-InstallState -StateRoot $stateRoot).payloadPath
        $planned = (Read-InstallState -StateRoot $stateRoot).installedVersion
        $fake = Get-PayloadDir -StateRoot $stateRoot -Version '9.9.9'
        New-Item -ItemType Directory -Path (Split-Path -Parent $fake) -Force | Out-Null
        Copy-Item -LiteralPath $payload -Destination $fake -Recurse -Force
        $backupDir = Join-Path (Get-BackupRoot -StateRoot $stateRoot) 'crash-sim'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $backupPayload = Join-Path $backupDir '0.4.1'
        Move-Item -LiteralPath $payload -Destination $backupPayload
        $snapshot = Get-RegistrationSnapshot -ProductPath $instance25.ProductPath
        $journal = [pscustomobject]@{
            id = 'crash-sim'; stage = 'commit'; startedAt = (Get-Date -Format 'o'); version = '9.9.9'
            payloadFinal = $fake; previousPayload = $payload; backupPath = $backupPayload
            snapshots = @($snapshot); stateBefore = (Read-InstallState -StateRoot $stateRoot)
            rollback = 'pending'; rollbackDetail = $null
        }
        Write-Journal -StateRoot $stateRoot -Journal $journal
        $saved = Read-InstallState -StateRoot $stateRoot
        $saved = [pscustomobject]@{ schemaVersion = 1; installedVersion = '9.9.9'; payloadPath = $fake; instances = $saved.instances }
        Save-InstallState -StateRoot $stateRoot -State $saved
        $result = Restore-PendingTransaction -StateRoot $stateRoot
        $after = Read-InstallState -StateRoot $stateRoot
        $result.Success -and $after.installedVersion -eq $planned -and (Test-Path -LiteralPath $payload) -and
            -not (Test-Path -LiteralPath $fake) -and -not (Test-Path (Get-JournalFile -StateRoot $stateRoot))
    }

    Write-Host ''
    Write-Host '=== 其它' -ForegroundColor Cyan
    Check '版本号比较方向正确' {
        (Compare-ProductVersion -Current '0.4.1' -Remote '0.4.0') -eq 1 -and
            (Compare-ProductVersion -Current '0.3.4' -Remote '0.4.0') -eq -1 -and
            (Compare-ProductVersion -Current '0.4.0' -Remote '0.4.0') -eq 0
    }
    Check 'TRUSTEDPATHS 拼接与精确移除' {
        $joined = Join-TrustedPath -Current 'A;B' -Add @('C', 'a')
        $removed = Remove-TrustedPath -Current $joined -Remove @('B')
        $joined -eq 'A;B;C' -and $removed -eq 'A;C'
    }
    Check '包装载信息与清单版本一致' {
        $info = Get-BundleInfo -Bundle $BundleDir
        $info.Version -eq $setup.releaseVersion
    }
    if (@(Get-CadProcess).Count -gt 0) {
        Check 'CAD 正在运行时拒绝安装（未进入测试模式）' {
            $env:CADMATH_SETUP_ALLOW_CAD_RUNNING = $null
            try { $r = Invoke-Cli -Extra @('-Install', 'R25.1\ACAD-9101:804', '-Yes') }
            finally { $env:CADMATH_SETUP_ALLOW_CAD_RUNNING = '1' }
            $r.ExitCode -ne 0 -and $r.Output -match 'AutoCAD 进程正在运行'
        }
    } else {
        Write-Host '  [SKIP] CAD 未运行，跳过"拒绝在 CAD 运行时安装"用例' -ForegroundColor Yellow
    }
} finally {
    Write-Host ''
    Write-Host '=== 清理' -ForegroundColor Cyan
    try { Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    try { if (Test-Path -LiteralPath $regRoot) { Remove-Item -LiteralPath $regRoot -Recurse -Force } } catch { }
    try { if (Test-Path -LiteralPath $machineRoot) { Remove-Item -LiteralPath $machineRoot -Recurse -Force } } catch { }
    $parent = Split-Path -Parent $regRoot
    try { if (Test-Path -LiteralPath $parent) { Remove-Item -LiteralPath $parent -Recurse -Force } } catch { }
    $parent = Split-Path -Parent $machineRoot
    try { if (Test-Path -LiteralPath $parent) { Remove-Item -LiteralPath $parent -Recurse -Force } } catch { }
    Write-Output '  已清理临时状态与假注册表'
}

Write-Host ''
Write-Host ('通过 {0} 项，失败 {1} 项' -f $passes, $failures.Count) -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
foreach ($item in $failures) { Write-Host ('  - ' + $item) -ForegroundColor Red }
if ($failures.Count -gt 0) { exit 1 }
exit 0
