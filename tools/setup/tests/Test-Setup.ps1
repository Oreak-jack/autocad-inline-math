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
if (-not $ZipPath) {
    # 不写死版本号：取 dist 里最新的正式 zip，避免每次发版都要改测试。
    $latest = @(Get-ChildItem -LiteralPath (Join-Path $scriptDir '..\..\..\dist') -Filter 'CadMath-InlineMath-*.zip' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'experimental' } | Sort-Object LastWriteTime -Descending) | Select-Object -First 1
    if ($latest) { $ZipPath = $latest.FullName }
}

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

    # 假注册表：一个 R25.1 实例（指向真实 AutoCAD 2026 目录，用来读构建号）+ 一个 R24.3 实例 + 一个 R23.1（2020）实例。
    $product25 = Join-Path $regRoot 'R25.1\ACAD-9101:804'
    $product24 = Join-Path $regRoot 'R24.3\ACAD-9010:409'
    $product23 = Join-Path $regRoot 'R23.1\ACAD-D001:804'
    New-Item -Path $product25 -Force | Out-Null
    New-Item -Path ($product25 + '\Profiles\<<未命名配置>>\Variables') -Force | Out-Null
    Set-ItemProperty -Path ($product25 + '\Profiles\<<未命名配置>>\Variables') -Name TRUSTEDPATHS -Value 'C:\Existing\Path'
    New-Item -Path $product24 -Force | Out-Null
    New-Item -Path $product23 -Force | Out-Null
    $product25a = Join-Path $regRoot 'R25.0\ACAD-A001:804'
    New-Item -Path $product25a -Force | Out-Null
    # 再补三个"只有键、没有安装目录"的旧实例，用来验证 2018 / 2017 / 2015-16 三档。
    $product22 = Join-Path $regRoot 'R22.0\ACAD-B001:804'
    $product21 = Join-Path $regRoot 'R21.0\ACAD-C001:804'
    $product20 = Join-Path $regRoot 'R20.1\ACAD-E001:804'
    New-Item -Path $product22 -Force | Out-Null
    New-Item -Path $product21 -Force | Out-Null
    New-Item -Path $product20 -Force | Out-Null
    $machine25 = Join-Path $machineRoot 'R25.1\ACAD-9101:804'
    $machine24 = Join-Path $machineRoot 'R24.3\ACAD-9010:409'
    $machine23 = Join-Path $machineRoot 'R23.1\ACAD-D001:804'
    New-Item -Path $machine25 -Force | Out-Null
    New-Item -Path $machine24 -Force | Out-Null
    New-Item -Path $machine23 -Force | Out-Null
    $machine25a = Join-Path $machineRoot 'R25.0\ACAD-A001:804'
    New-Item -Path $machine25a -Force | Out-Null
    $machine22 = Join-Path $machineRoot 'R22.0\ACAD-B001:804'
    $machine21 = Join-Path $machineRoot 'R21.0\ACAD-C001:804'
    $machine20 = Join-Path $machineRoot 'R20.1\ACAD-E001:804'
    New-Item -Path $machine22 -Force | Out-Null
    New-Item -Path $machine21 -Force | Out-Null
    New-Item -Path $machine20 -Force | Out-Null
    Set-ItemProperty -Path $machine22 -Name AcadLocation -Value 'C:\Program Files\Autodesk\AutoCAD 2018\'
    Set-ItemProperty -Path $machine21 -Name AcadLocation -Value 'C:\Program Files\Autodesk\AutoCAD 2017\'
    Set-ItemProperty -Path $machine20 -Name AcadLocation -Value 'C:\Program Files\Autodesk\AutoCAD 2016\'
    Set-ItemProperty -Path $machine25a -Name AcadLocation -Value 'C:\Program Files\Autodesk\AutoCAD 2025\'
    Set-ItemProperty -Path $machine25 -Name AcadLocation -Value 'D:\AutoCAD 2026\'
    Set-ItemProperty -Path $machine24 -Name AcadLocation -Value 'C:\Program Files\Autodesk\AutoCAD 2024\'
    Set-ItemProperty -Path $machine23 -Name AcadLocation -Value 'C:\Program Files\Autodesk\AutoCAD 2020\'
    Write-Output '  假注册表已建立'

    $scan = Invoke-EnvironmentScan -RegistryRoot $regRoot -MachineRegistryRoot $machineRoot -AppsRoot $appsRoot -StateRoot $stateRoot
    $setup = Read-SetupManifest -Path $SetupJson
    $instance25 = @($scan.Instances | Where-Object { $_.Release -eq 'R25.1' })[0]
    $instance25a = @($scan.Instances | Where-Object { $_.Release -eq 'R25.0' })[0]
    $instance24 = @($scan.Instances | Where-Object { $_.Release -eq 'R24.3' })[0]
    $instance23 = @($scan.Instances | Where-Object { $_.Release -eq 'R23.1' })[0]
    $instance22 = @($scan.Instances | Where-Object { $_.Release -eq 'R22.0' })[0]
    $instance21 = @($scan.Instances | Where-Object { $_.Release -eq 'R21.0' })[0]
    $instance20 = @($scan.Instances | Where-Object { $_.Release -eq 'R20.1' })[0]

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
    Check '2026 实例匹配到 modern-r26' {
        $m = Select-AdapterForInstance -Setup $setup -Instance $instance25 -Architecture 'x64'
        $m.Status -eq 'matched' -and $m.Adapter.id -eq 'modern-r26'
    }
    Check '2025 实例匹配到 modern-r25（用 2025 的 SDK 编译的那一份）' {
        $m = Select-AdapterForInstance -Setup $setup -Instance $instance25a -Architecture 'x64'
        $m.Status -eq 'matched' -and $m.Adapter.id -eq 'modern-r25'
    }
    Check '2024 实例匹配到 legacy-r24（0.4.3 起转为正式支持）' {
        $m = Select-AdapterForInstance -Setup $setup -Instance $instance24 -Architecture 'x64'
        $m.Status -eq 'matched' -and $m.Adapter.id -eq 'legacy-r24'
    }
    Check '宿主按 CAD 系列选择入口 DLL（七档：2026→Win64，2025→Win64-2025，2021–2024→Win64-2024，2020→Win64-2020，2018→Win64-2018，2017→Win64-2017，2015–2016→Win64-2015）' {
        $h26 = Get-HostForSeries -Setup $setup -Series 'R25.1'
        $h25 = Get-HostForSeries -Setup $setup -Series '25.0'
        $h24 = Get-HostForSeries -Setup $setup -Series '24.3'
        $h23 = Get-HostForSeries -Setup $setup -Series 'R23.1'
        $h22 = Get-HostForSeries -Setup $setup -Series 'R22.0'
        $h21 = Get-HostForSeries -Setup $setup -Series 'R21.0'
        $h20 = Get-HostForSeries -Setup $setup -Series 'R20.1'
        $h20a = Get-HostForSeries -Setup $setup -Series 'R20.0'
        $h26.entry -eq 'Contents/Win64/CadMath03.dll' -and
            $h25.entry -eq 'Contents/Win64-2025/CadMath03.dll' -and
            $h24.entry -eq 'Contents/Win64-2024/CadMath03.dll' -and
            $h23.entry -eq 'Contents/Win64-2020/CadMath03.dll' -and
            $h22.entry -eq 'Contents/Win64-2018/CadMath03.dll' -and
            $h21.entry -eq 'Contents/Win64-2017/CadMath03.dll' -and
            $h20.entry -eq 'Contents/Win64-2015/CadMath03.dll' -and
            $h20a.entry -eq 'Contents/Win64-2015/CadMath03.dll' -and
            $null -eq (Get-HostForSeries -Setup $setup -Series 'R19.1')
    }
    Check '2018 / 2017 / 2015–2016 三个实例各自匹配到自己的适配器' {
        $m22 = Select-AdapterForInstance -Setup $setup -Instance $instance22 -Architecture 'x64'
        $m21 = Select-AdapterForInstance -Setup $setup -Instance $instance21 -Architecture 'x64'
        $m20 = Select-AdapterForInstance -Setup $setup -Instance $instance20 -Architecture 'x64'
        $m22.Status -eq 'matched' -and $m22.Adapter.id -eq 'legacy-r22' -and
            $m21.Status -eq 'matched' -and $m21.Adapter.id -eq 'legacy-r21' -and
            $m20.Status -eq 'matched' -and $m20.Adapter.id -eq 'legacy-r20'
    }
    Check '清单拒绝重复的宿主 series' {
        $bad = Join-Path $root 'dup-host.json'
        $clone = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $clone.hosts[1].series = @('R25.0')
        [IO.File]::WriteAllText($bad, ($clone | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($true)))
        Expect-Throws { Read-SetupManifest -Path $bad } '*重复*'
    }
    Check '2024 适配器在实验许可下可匹配' {
        $m = Select-AdapterForInstance -Setup $setup -Instance $instance24 -Architecture 'x64' -AllowExperimental
        $m.Status -eq 'matched' -and $m.Adapter.id -eq 'legacy-r24'
    }
    Check '2020 实例默认被拒绝（legacy-r23 是 planned），实验许可下可匹配' {
        $plain = Select-AdapterForInstance -Setup $setup -Instance $instance23 -Architecture 'x64'
        $plainReasons = @($plain.Rejections | ForEach-Object { $_.Reason })
        $exp = Select-AdapterForInstance -Setup $setup -Instance $instance23 -Architecture 'x64' -AllowExperimental
        $plain.Status -eq 'none' -and ($plainReasons -contains 'status-planned') -and
            $exp.Status -eq 'matched' -and $exp.Adapter.id -eq 'legacy-r23'
    }
    Check '2020 安装后 LOADER 指向 Win64-2020，2026 仍指向 Win64' {
        $expSetup = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($adapter in @($expSetup.adapters)) { if ($adapter.id -eq 'legacy-r23') { $adapter.status = 'built' } }
        $expPath = Join-Path $root 'experimental-setup-2020.json'
        [IO.File]::WriteAllText($expPath, ($expSetup | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($true)))
        $parsed = Read-SetupManifest -Path $expPath

        $state23 = Join-Path $root 'state-2020'
        $r23 = Install-CadMathPackage -Setup $parsed -SourcePath $BundleDir -Instances @($instance23) -StateRoot $state23 -Architecture 'x64'
        $loader23 = if ($r23.Success) { $r23.Loader } else { '' }
        $stateDoc = Read-InstallState -StateRoot $state23
        $entry23 = if ($stateDoc.instances.Count -gt 0) { $stateDoc.instances[0].entry } else { '' }
        $null = Uninstall-CadMathInstances -Instances @($instance23) -StateRoot $state23

        $r23.Success -and ($loader23 -match 'Win64-2020\\CadMath03\.dll$') -and ($entry23 -eq 'Contents\Win64-2020\CadMath03.dll')
    }
    Check '2024 安装后 LOADER 指向 Win64-2024，2026 仍指向 Win64' {
        $expSetup = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($adapter in @($expSetup.adapters)) { if ($adapter.id -eq 'legacy-r24') { $adapter.status = 'built' } }
        $expPath = Join-Path $root 'experimental-setup.json'
        [IO.File]::WriteAllText($expPath, ($expSetup | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($true)))
        $parsed = Read-SetupManifest -Path $expPath

        $state24 = Join-Path $root 'state-2024'
        $r24 = Install-CadMathPackage -Setup $parsed -SourcePath $BundleDir -Instances @($instance24) -StateRoot $state24 -Architecture 'x64'
        $loader24 = if ($r24.Success) { $r24.Loader } else { '' }
        $stateDoc = Read-InstallState -StateRoot $state24
        $entry24 = if ($stateDoc.instances.Count -gt 0) { $stateDoc.instances[0].entry } else { '' }
        $null = Uninstall-CadMathInstances -Instances @($instance24) -StateRoot $state24

        $state25 = Join-Path $root 'state-2026'
        $r25 = Install-CadMathPackage -Setup $parsed -SourcePath $BundleDir -Instances @($instance25) -StateRoot $state25 -Architecture 'x64'
        $loader25 = if ($r25.Success) { $r25.Loader } else { '' }
        $null = Uninstall-CadMathInstances -Instances @($instance25) -StateRoot $state25

        $r24.Success -and $r25.Success -and ($loader24 -match 'Win64-2024\\CadMath03\.dll$') -and ($entry24 -eq 'Contents\Win64-2024\CadMath03.dll') -and ($loader25 -match 'Win64\\CadMath03\.dll$')
    }
    Check '清单里的产品 appKey 重复会被拒绝' {
        $dup = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $products = @($dup.products)
        if ($products.Count -lt 2) { return $false }
        $products[1].appKey = $products[0].appKey
        $dupPath = Join-Path $root 'setup-dup-products.json'
        [IO.File]::WriteAllText($dupPath, ($dup | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($true)))
        $threw = $false
        try { $null = Read-SetupManifest -Path $dupPath } catch { $threw = $true }
        $threw
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
        $r.ExitCode -eq 0 -and @($parsed.CadInstances).Count -eq 7
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
    Check '两件产品各自注册到同一实例，LOADER 指向各自的 DLL' {
        $cadKey = Get-RegistrationKey -ProductPath $instance25.ProductPath -AppKey 'CadMathInlineMath'
        $imeKey = Get-RegistrationKey -ProductPath $instance25.ProductPath -AppKey 'OreakContextInput'
        if (-not (Test-Path -LiteralPath $cadKey) -or -not (Test-Path -LiteralPath $imeKey)) { return $false }
        $cadLoader = [string](Get-ItemProperty -LiteralPath $cadKey).LOADER
        $imeLoader = [string](Get-ItemProperty -LiteralPath $imeKey).LOADER
        $state = Read-InstallState -StateRoot $stateRoot
        $products = @($state.instances[0].products)
        ($cadLoader -like '*CadMath03.dll') -and ($imeLoader -like '*Oreak.ContextInput.dll') -and
            (Test-Path -LiteralPath $cadLoader) -and (Test-Path -LiteralPath $imeLoader) -and
            ($products.Count -eq 2)
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
    Check '给 2020 安装会被拒绝（legacy-r23 仍是 planned），退出码 3' {
        $r = Invoke-Cli -Extra @('-Install', 'R23.1\ACAD-D001:804', '-Yes')
        $r.ExitCode -eq 3 -and $r.Output -match '没有可用适配器'
    }
    Check '卸载 2026 实例成功并清理注册项' {
        $r = Invoke-Cli -Extra @('-Remove', 'R25.1\ACAD-9101:804', '-Yes')
        $key = Get-RegistrationKey -ProductPath $instance25.ProductPath
        $r.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $key)
    }
    Check '卸载会把两件产品一起清掉' {
        $cadKey = Get-RegistrationKey -ProductPath $instance25.ProductPath -AppKey 'CadMathInlineMath'
        $imeKey = Get-RegistrationKey -ProductPath $instance25.ProductPath -AppKey 'OreakContextInput'
        (-not (Test-Path -LiteralPath $cadKey)) -and (-not (Test-Path -LiteralPath $imeKey))
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
            $state.installedVersion -eq $setup.releaseVersion -and (Test-Path -LiteralPath $loader) -and
            -not (Test-Path (Get-JournalFile -StateRoot $stateRoot))
    }
    Check '--Rollback 能把实例指回备份里的旧版本' {
        # 0.5.0 任务 4：安装 -> 制造一份备份 -> 改注册项 -> -Rollback 恢复
        $first = Invoke-Cli -Extra @('-Install', 'R25.1\ACAD-9101:804', '-Yes')
        if ($first.ExitCode -ne 0) { return $false }
        $payload = (Read-InstallState -StateRoot $stateRoot).payloadPath
        $backupDir = Join-Path (Get-BackupRoot -StateRoot $stateRoot) '20260101-000000-manual'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Copy-Item -LiteralPath $payload -Destination (Join-Path $backupDir (Split-Path -Leaf $payload)) -Recurse -Force
        $key = Get-RegistrationKey -ProductPath $instance25.ProductPath
        Set-ItemProperty -LiteralPath $key -Name 'LOADER' -Value 'C:\nowhere\CadMath03.dll'
        $r = Invoke-Cli -Extra @('-Rollback', '-Yes')
        $state = Read-InstallState -StateRoot $stateRoot
        $loader = (Get-ItemProperty -LiteralPath $key).LOADER
        $r.ExitCode -eq 0 -and $r.Output -match '回滚完成' -and (Test-Path -LiteralPath $loader) -and
            $loader -match 'restore' -and $state.payloadPath -match 'restore'
    }
    Check '回滚失败时保留事务记录，重启后可恢复' {
        $payload = (Read-InstallState -StateRoot $stateRoot).payloadPath
        $planned = (Read-InstallState -StateRoot $stateRoot).installedVersion
        $fake = Get-PayloadDir -StateRoot $stateRoot -Version '9.9.9'
        New-Item -ItemType Directory -Path (Split-Path -Parent $fake) -Force | Out-Null
        Copy-Item -LiteralPath $payload -Destination $fake -Recurse -Force
        $backupDir = Join-Path (Get-BackupRoot -StateRoot $stateRoot) 'crash-sim'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $backupPayload = Join-Path $backupDir $setup.releaseVersion
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
    Check 'PS 5.1 的 @(泛型List) 陷阱已用 ConvertTo-ItemArray 规避' {
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add([pscustomobject]@{ A = 1 })
        $list.Add([pscustomobject]@{ A = 2 })
        $converted = ConvertTo-ItemArray -Value $list
        $single = ConvertTo-ItemArray -Value ([pscustomobject]@{ A = 3 })
        $none = ConvertTo-ItemArray -Value $null
        $converted.Count -eq 2 -and $single.Count -eq 1 -and $none.Count -eq 0 -and $converted[1].A -eq 2
    }
    Check 'ApplicationPlugins 模式装到指定目录、不写注册表' {
        $gApps = Join-Path $root 'global-apps'
        $gState = Join-Path $root 'global-state'
        $out = & $powershell -NoProfile -ExecutionPolicy Bypass -File $entry -Install 'dummy' -Mode appplugins -Yes `
            -SetupJson $SetupJson -FromBundle $BundleDir -StateRoot $gState `
            -RegistryRoot $regRoot -MachineRegistryRoot $machineRoot -AppsRoot $gApps 2>&1 | Out-String
        $code = $LASTEXITCODE
        $manifest = Join-Path $gApps 'CadMath03.bundle\PackageContents.xml'
        $stateFile = Join-Path $gState 'state.json'
        $ok = $false
        if ($code -eq 0 -and (Test-Path -LiteralPath $manifest) -and (Test-Path -LiteralPath $stateFile)) {
            $st = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            $registered = Test-Path -LiteralPath (Get-RegistrationKey -ProductPath $instance24.ProductPath)
            $ok = ($st.mode -eq 'appplugins') -and ($st.installedVersion -eq $setup.releaseVersion) -and (-not $registered)
        }
        if (-not $ok) {
            $dump = Join-Path $env:TEMP 'cm-global-fail.log'
            [IO.File]::WriteAllText($dump, $out, (New-Object Text.UTF8Encoding($true)))
            throw ('退出码 {0}；完整输出见 {1}' -f $code, $dump)
        }
        $ok
    }
    Check 'ApplicationPlugins 模式卸载会移除目录并重置状态' {
        $gApps = Join-Path $root 'global-apps'
        $gState = Join-Path $root 'global-state'
        $out = & $powershell -NoProfile -ExecutionPolicy Bypass -File $entry -Remove 'dummy' -Yes `
            -StateRoot $gState -RegistryRoot $regRoot -MachineRegistryRoot $machineRoot -AppsRoot $gApps 2>&1 | Out-String
        $code = $LASTEXITCODE
        $st = Get-Content -LiteralPath (Join-Path $gState 'state.json') -Raw | ConvertFrom-Json
        $code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $gApps 'CadMath03.bundle')) -and $null -eq $st.installedVersion
    }
    Check '旧式安装的存在判断以磁盘为准（缓存说还在、实际已删则不拦）' {
        $ghost = [pscustomobject]@{ Present = $true; Path = (Join-Path $root 'no-such-bundle'); Version = '0.4.1' }
        $real = [pscustomobject]@{ Present = $true; Path = $BundleDir; Version = '0.4.1' }
        $absent = [pscustomobject]@{ Present = $false; Path = $BundleDir; Version = $null }
        (-not (Test-LegacyInstallPresent -Legacy $ghost)) -and (Test-LegacyInstallPresent -Legacy $real) -and (-not (Test-LegacyInstallPresent -Legacy $absent))
    }
    Check '启动批处理是 CRLF 且纯 ASCII（否则 cmd.exe 会解析错乱闪退）' {
        $launchers = @(
            (Join-Path $PSScriptRoot '..\CadMath-Setup.cmd'),
            (Join-Path $PSScriptRoot '..\..\..\dist\CadMath-Setup.cmd')
        )
        $ok = $true
        $checked = 0
        foreach ($path in $launchers) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $checked++
            $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $path))
            $cr = @($bytes | Where-Object { $_ -eq 13 }).Count
            $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
            $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
            if ($cr -ne $lf -or $nonAscii -gt 0) { $ok = $false }
        }
        $ok -and $checked -ge 1
    }
    Check '从 zip 安装：清单里没有 zip 字段也不崩（0.4.5 的更新失败）' {
        # 复现 2024 机器上的报错：`$Setup.zip` 在 StrictMode 下直接抛"找不到属性"。
        $stripped = Join-Path $root 'setup-nozip.json'
        $doc = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($doc.PSObject.Properties['zip']) { $doc.PSObject.Properties.Remove('zip') }
        [IO.File]::WriteAllText($stripped, ($doc | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath)) { return $false }
        $zipState = Join-Path $root 'state-zip'
        $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entry,
            '-Install', 'R25.1\ACAD-9101:804', '-Yes', '-FromZip', $ZipPath,
            '-SetupJson', $stripped, '-StateRoot', $zipState, '-RegistryRoot', $cli.RegistryRoot,
            '-MachineRegistryRoot', $cli.MachineRegistryRoot, '-AppsRoot', $cli.AppsRoot)
        $out = & $powershell @cliArgs 2>&1 | Out-String
        $key = Get-RegistrationKey -ProductPath $instance25.ProductPath
        if ($LASTEXITCODE -ne 0 -or $out -match '找不到属性') {
            $dump = Join-Path $env:TEMP 'cm-zip-fail.log'
            [IO.File]::WriteAllText($dump, $out, (New-Object Text.UTF8Encoding($true)))
            throw ('退出码 {0}；完整输出见 {1}' -f $LASTEXITCODE, $dump)
        }
        $loader = (Get-ItemProperty -LiteralPath $key).LOADER
        (Test-Path -LiteralPath $loader) -and $loader -like "*$zipState*"
    }
    Check '从带"来自网络"标记的目录安装后，负载文件不再被标记（0.4.8 在 2024 上的加载失败）' {
        # 复现 2024 机器：浏览器下载的 zip 解出来的 dll 带 Zone.Identifier，
        # .NET Framework 的 LoadFrom 会以 0x80131515 拒绝加载。
        $markedPackage = Join-Path $root 'pkg-marked'
        $markedBundle = Join-Path $markedPackage 'CadMath03.bundle'
        if (-not (Test-Path -LiteralPath $markedBundle)) {
            # 清单的 files[] 覆盖三个 bundle，所以整个发行包都要复制过来。
            New-Item -ItemType Directory -Path $markedPackage -Force | Out-Null
            foreach ($bundleDir in @(Get-ChildItem -LiteralPath (Split-Path -Parent $BundleDir) -Directory -Filter '*.bundle')) {
                Copy-Item -LiteralPath $bundleDir.FullName -Destination (Join-Path $markedPackage $bundleDir.Name) -Recurse -Force
            }
            foreach ($dll in @(Get-ChildItem -LiteralPath $markedPackage -Recurse -File -Filter '*.dll')) {
                Set-Content -LiteralPath $dll.FullName -Stream 'Zone.Identifier' -Value ("[ZoneTransfer]`r`nZoneId=3`r`n") -Encoding Ascii
            }
        }
        $markedState = Join-Path $root 'state-marked'
        $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entry,
            '-Install', 'R25.1\ACAD-9101:804', '-Yes', '-FromBundle', $markedBundle,
            '-SetupJson', $SetupJson, '-StateRoot', $markedState, '-RegistryRoot', $cli.RegistryRoot,
            '-MachineRegistryRoot', $cli.MachineRegistryRoot, '-AppsRoot', $cli.AppsRoot)
        $markedOut = & $powershell @cliArgs 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw ('退出码 {0}：{1}' -f $LASTEXITCODE, $markedOut) }
        $markedVersion = [string]$setup.releaseVersion
        $payloadDll = Join-Path $markedState ('payload\' + $markedVersion + '\Contents\Win64\CadMath03.dll')
        if (-not (Test-Path -LiteralPath $payloadDll)) { throw ('负载里没有 {0}' -f $payloadDll) }
        $left = 0
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $markedState ('payload\' + $markedVersion)) -Recurse -File)) {
            try { $null = Get-Item -LiteralPath $file.FullName -Stream Zone.Identifier -ErrorAction Stop; $left++ } catch { }
        }
        $left -eq 0
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
