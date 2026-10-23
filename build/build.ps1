#requires -Version 5.1
<#
.SYNOPSIS
    构建 CadMath03.bundle、命令行安装器与发行包。

.DESCRIPTION
    1. 从 Directory.Build.props 读取唯一版本号；
    2. 编译三个宿主：net8（2025/2026）、net48·24.3（2021–2024）、net48·23.1（2020），以及各自适配器；
    3. 组装 bundle：Contents\Win64、Contents\Win64-2024、Contents\Win64-2020；
    4. 生成 setup.json（发行清单：hosts、逐文件 SHA-256、适配器状态）；
    5. 组装发行 zip（bundle + 安装器 + setup.json）并生成 SHA256SUMS.txt。

.PARAMETER Experimental
    把尚未真机验证的适配器（legacy-r24 / legacy-r23）状态从 planned 提升为 built，产出实验包。
    正式发行不要带这个开关：没验证过的适配器默认不装。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\build.ps1

    # 给测试者的实验包
    powershell -ExecutionPolicy Bypass -File build\build.ps1 -Experimental
#>
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [switch]$NoZip,
    [switch]$Experimental
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Resolve-Dotnet {
    # 本机可能同时存在"只有运行时、没有 SDK"的 dotnet，所以先试已经装了 SDK 的那个。
    $candidates = @(
        (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),
        (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')
    )

    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path $candidate)) { continue }
        $sdks = & $candidate --list-sdks 2>$null
        if ($LASTEXITCODE -eq 0 -and $sdks) { return $candidate }
    }

    throw '找不到带 SDK 的 dotnet。请安装 .NET SDK。'
}

$dotnet = Resolve-Dotnet

# ---- 版本单一来源 -------------------------------------------------------
[xml]$props = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Directory.Build.props')
$version = $props.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
if (-not $version) { throw 'Directory.Build.props 里没有 <Version>。' }

$dist = Join-Path $root 'dist'
$bundle = Join-Path $dist 'CadMath03.bundle'
$bundle2024 = Join-Path $dist 'CadMath03-2024.bundle'
$bundle2020 = Join-Path $dist 'CadMath03-2020.bundle'
$win64 = Join-Path $bundle 'Contents\Win64'
$win64_2024 = Join-Path $bundle 'Contents\Win64-2024'
$win64_2020 = Join-Path $bundle 'Contents\Win64-2020'
$staging = Join-Path $root 'objs\publish'

Write-Host "CadMath $version  |  $Configuration  |  Experimental=$($Experimental.IsPresent)"

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $win64, (Join-Path $win64 'Adapters'), $win64_2024, (Join-Path $win64_2024 'Adapters'), $win64_2020, (Join-Path $win64_2020 'Adapters'), $staging | Out-Null

function Build-Project([string]$project, [string]$output, [string]$framework = '', [string[]]$properties = @()) {
    Write-Host "  构建 $project $framework $($properties -join ' ')"
    $arguments = @(
        'build', (Join-Path $root $project),
        '-c', $Configuration,
        ('-p:Version=' + $version),
        '-o', $output,
        '--nologo', '-v', 'q'
    )
    if ($framework) { $arguments += @('-f', $framework) }
    foreach ($property in $properties) { $arguments += @($property) }
    # 同一个工程要用不同的 AutoCAD 引用编三次，必须强制重新编译，否则增量构建会复用上一次的中间产物。
    $arguments += @('-t:Rebuild')

    & $dotnet @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "构建失败：$project $framework $($properties -join ' ')" }
}

# ---- 三个宿主：目录、目标框架、AutoCAD 引用版本 -------------------------
$hostsPlan = @(
    [ordered]@{ key = 'win64'; dir = $win64; framework = 'net8.0-windows'; staging = 'shell-net8'; properties = @('-p:AcadSdkVersion=25.1.0'); note = '2025 / 2026 · .NET 8'; sdk = '25.1.0' },
    [ordered]@{ key = 'win64-2024'; dir = $win64_2024; framework = 'net48'; staging = 'shell-net48-2024'; properties = @('-p:AcadLegacySdkVersion=24.3.0'); note = '2021–2024 · .NET Framework 4.8'; sdk = '24.3.0' },
    [ordered]@{ key = 'win64-2020'; dir = $win64_2020; framework = 'net48'; staging = 'shell-net48-2020'; properties = @('-p:AcadLegacySdkVersion=23.1.0'); note = '2020 · .NET Framework 4.8'; sdk = '23.1.0' }
)

$adaptersPlan = @(
    [ordered]@{ key = 'modern'; project = 'src\CadMath.Adapter.Modern\CadMath.Adapter.Modern.csproj'; host = 'win64'; file = 'CadMath.Adapter.Modern.dll' },
    [ordered]@{ key = 'legacy2024'; project = 'src\CadMath.Adapter.Legacy2024\CadMath.Adapter.Legacy2024.csproj'; host = 'win64-2024'; file = 'CadMath.Adapter.Legacy2024.dll' },
    [ordered]@{ key = 'legacy2020'; project = 'src\CadMath.Adapter.Legacy2020\CadMath.Adapter.Legacy2020.csproj'; host = 'win64-2020'; file = 'CadMath.Adapter.Legacy2020.dll' }
)

Write-Host '构建 Shell（三个宿主）'
foreach ($plan in $hostsPlan) {
    Build-Project 'src\CadMath.Shell\CadMath.Shell.csproj' (Join-Path $staging $plan.staging) $plan.framework $plan.properties
}

Write-Host '构建适配器'
foreach ($plan in $adaptersPlan) {
    Build-Project $plan.project (Join-Path $staging $plan.key)
}

# ---- 运行时清单（每个宿主目录一份，只列出自己能用的适配器） ---------------
$allAdapters = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'adapters\adapters.json') | ConvertFrom-Json

function Get-AdapterHost([object]$adapter) {
    if ($adapter.PSObject.Properties['host'] -and $adapter.host) { return [string]$adapter.host }
    if ([string]$adapter.runtime -eq 'net8.0-windows') { return 'win64' }
    return 'win64-2024'
}

function Write-RuntimeManifest([string]$path, [string]$hostKey) {
    $pick = @($allAdapters.adapters | Where-Object { (Get-AdapterHost $_) -eq $hostKey })
    if ($pick.Count -eq 0) { throw "宿主 $hostKey 没有对应的适配器。" }

    $manifest = [ordered]@{
        schemaVersion = [int]$allAdapters.schemaVersion
        adapters      = $pick
    }
    [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}

# ---- 组装宿主体 ---------------------------------------------------------
$hostFiles = @('CadMath03.dll', 'CadMath.Core.dll', 'CadMath.Abstractions.dll')
foreach ($plan in $hostsPlan) {
    foreach ($file in $hostFiles) {
        Copy-Item (Join-Path (Join-Path $staging $plan.staging) $file) $plan.dir
    }
    Write-RuntimeManifest (Join-Path $plan.dir 'adapters.json') $plan.key
}

foreach ($plan in $adaptersPlan) {
    $target = @($hostsPlan | Where-Object { $_.key -eq $plan.host })[0]
    Copy-Item (Join-Path (Join-Path $staging $plan.key) $plan.file) (Join-Path $target.dir 'Adapters')
}

# ---- PackageContents 与构建信息 ----------------------------------------
function Write-ApplicationPackage([string]$template, [string]$targetFile) {
    $text = Get-Content -Raw -Encoding UTF8 (Join-Path $root $template)
    $text = $text.Replace('__CADMATH_VERSION__', $version)
    [IO.File]::WriteAllText($targetFile, $text, (New-Object Text.UTF8Encoding($false)))
}

Write-ApplicationPackage 'bundle\PackageContents.xml' (Join-Path $bundle 'PackageContents.xml')

# 2024 / 2020 各出一份独立 bundle（给 ApplicationPlugins 全局安装用），内容取自各自的宿主体
New-Item -ItemType Directory -Force -Path (Join-Path $bundle2024 'Contents') | Out-Null
Copy-Item -Recurse -Force $win64_2024 (Join-Path $bundle2024 'Contents\Win64-2024')
Write-ApplicationPackage 'bundle\PackageContents-2024.xml' (Join-Path $bundle2024 'PackageContents.xml')

New-Item -ItemType Directory -Force -Path (Join-Path $bundle2020 'Contents') | Out-Null
Copy-Item -Recurse -Force $win64_2020 (Join-Path $bundle2020 'Contents\Win64-2020')
Write-ApplicationPackage 'bundle\PackageContents-2020.xml' (Join-Path $bundle2020 'PackageContents.xml')

$buildInfo = @"
CadMath03 $version
构建时间: $(Get-Date -Format o)
配置: $Configuration
实验包: $($Experimental.IsPresent)

[2025 / 2026 · .NET 8]  Contents/Win64
  CadMath03.dll            (net8.0-windows, 官方 NuGet 25.1.0 引用)
  Adapters/CadMath.Adapter.Modern.dll

[2021–2024 · .NET Framework 4.8]  Contents/Win64-2024
  CadMath03.dll            (net48, 官方 NuGet 24.3.0 引用)
  Adapters/CadMath.Adapter.Legacy2024.dll

[2020 · .NET Framework 4.8]  Contents/Win64-2020
  CadMath03.dll            (net48, 官方 NuGet 23.1.0 引用)
  Adapters/CadMath.Adapter.Legacy2020.dll
"@
[IO.File]::WriteAllText((Join-Path $bundle 'BUILD-INFO.txt'), $buildInfo, (New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText((Join-Path $bundle2024 'BUILD-INFO.txt'), $buildInfo, (New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText((Join-Path $bundle2020 'BUILD-INFO.txt'), $buildInfo, (New-Object Text.UTF8Encoding($true)))

# ---- 发行清单 setup.json ------------------------------------------------
$hosts = @(
    [ordered]@{ series = @('R25.0', 'R25.1'); runtime = 'net8.0-windows'; entry = 'Contents/Win64/CadMath03.dll'; bundle = 'CadMath03.bundle' },
    [ordered]@{ series = @('R24.0', 'R24.1', 'R24.2', 'R24.3'); runtime = 'net48'; entry = 'Contents/Win64-2024/CadMath03.dll'; bundle = 'CadMath03-2024.bundle' },
    [ordered]@{ series = @('R23.1'); runtime = 'net48'; entry = 'Contents/Win64-2020/CadMath03.dll'; bundle = 'CadMath03-2020.bundle' }
)

$releaseAdapters = @()
foreach ($adapter in @($allAdapters.adapters)) {
    $status = 'built'
    if ($adapter.PSObject.Properties['status'] -and $adapter.status) { $status = [string]$adapter.status }

    if ($Experimental -and $status -eq 'planned') { $status = 'built' }

    $hostKey = Get-AdapterHost $adapter
    $hostPlan = @($hostsPlan | Where-Object { $_.key -eq $hostKey })[0]
    $relativeHost = $hostPlan.dir.Substring($bundle.Length + 1).Replace('\', '/')
    $releaseAdapters += [ordered]@{
        id           = [string]$adapter.id
        path         = $relativeHost + '/Adapters/' + (Split-Path ([string]$adapter.assembly) -Leaf)
        cadSeries    = @($adapter.series)
        runtime      = [string]$adapter.runtime
        architecture = 'x64'
        status       = $status
        evidence     = @()
        limitations  = @()
    }
}

$files = @()
foreach ($item in @(Get-ChildItem -LiteralPath $dist -Recurse -File -Filter * | Where-Object { $_.FullName -notmatch '\\tools\\|CadMath-Setup\.cmd$|setup\.json$|SHA256SUMS\.txt$' } | Sort-Object FullName)) {
    $relative = $item.FullName.Substring($dist.Length + 1).Replace('\', '/')
    $files += [ordered]@{
        path   = $relative
        size   = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$supportedSeries = @($releaseAdapters | ForEach-Object { $_.cadSeries } | Sort-Object -Unique)

# zip 段保留给旧版安装器读（0.4.2~0.4.4 的 StrictMode 会直接访问 $Setup.zip）；
# 哈希留空，实际校验值在 SHA256SUMS.txt 与 Release 资产里，新版工具走逐文件校验。
$zipName = if ($Experimental) { "CadMath-InlineMath-$version-experimental.zip" } else { "CadMath-InlineMath-$version.zip" }

$setup = [ordered]@{
    schemaVersion   = 1
    product         = 'CadMath'
    productCode     = '{04913737-F911-4978-9F6B-2DB24F3DCC03}'
    releaseVersion  = $version
    toolVersion     = $version
    experimental    = [bool]$Experimental.IsPresent
    bundleName      = 'CadMath03.bundle'
    zip             = [ordered]@{ name = $zipName; sha256 = $null }
    hosts           = $hosts
    supportedSeries = $supportedSeries
    adapters        = $releaseAdapters
    files           = $files
}
$setupJson = $setup | ConvertTo-Json -Depth 10
# 中文标签要保留：用 UTF-8 无 BOM 写，PowerShell 的 ConvertFrom-Json 与 C# 端都能读。
[IO.File]::WriteAllText((Join-Path $dist 'setup.json'), $setupJson, (New-Object Text.UTF8Encoding($false)))

# ---- 安装器 -------------------------------------------------------------
Copy-Item (Join-Path $root 'tools\setup\CadMath-Setup.cmd') $dist
$distTools = Join-Path $dist 'tools\setup'
New-Item -ItemType Directory -Path $distTools -Force | Out-Null
Copy-Item -Path (Join-Path $root 'tools\setup\*') -Destination $distTools -Recurse -Force

Write-Host ''
Get-ChildItem $dist -Recurse -File | Where-Object { $_.FullName -notmatch '\\tools\\' } | ForEach-Object { '  ' + $_.FullName.Substring($dist.Length + 1) }

if (-not $NoZip) {
    $name = $zipName
    $zip = Join-Path $dist $name
    $items = @(
        $bundle,
        $bundle2024,
        $bundle2020,
        (Join-Path $dist 'CadMath-Setup.cmd'),
        (Join-Path $dist 'tools'),
        (Join-Path $dist 'setup.json')
    )
    Compress-Archive -Path $items -DestinationPath $zip -Force
    $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), ('{0}  {1}' -f $zipHash, $Name) + "`n", (New-Object Text.UTF8Encoding($false)))
    Write-Host "`n  打包: $zip"
    Write-Host "  校验: $zipHash"
}

Write-Host ''
Write-Host '完成。'
Write-Host '  2025/2026：Contents\Win64；2021–2024：Contents\Win64-2024；2020：Contents\Win64-2020。'
