#requires -Version 5.1
<#
.SYNOPSIS
    构建 CadMath03.bundle、命令行安装器与发行包。

.DESCRIPTION
    1. 从 Directory.Build.props 读取唯一版本号；
    2. 编译 Shell（net8 + net48 两代）与两个适配器；
    3. 组装 bundle：Contents\Win64（2025/2026，net8）与 Contents\Win64-2024（2024，net48）；
    4. 生成 setup.json（发行清单：hosts、逐文件 SHA-256、适配器状态）；
    5. 组装发行 zip（bundle + 安装器 + setup.json）并生成 SHA256SUMS.txt。

.PARAMETER Experimental
    把尚未真机验证的适配器（legacy-r24）状态从 planned 提升为 built，产出实验包。
    正式发行不要带这个开关：2024 在验证通过前，正式包默认不装它。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\build.ps1

    # 给测试者的 2024 实验包
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
$win64 = Join-Path $bundle 'Contents\Win64'
$win64_2024 = Join-Path $bundle 'Contents\Win64-2024'
$staging = Join-Path $root 'objs\publish'

Write-Host "CadMath $version  |  $Configuration  |  Experimental=$($Experimental.IsPresent)"

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $win64, (Join-Path $win64 'Adapters'), $win64_2024, (Join-Path $win64_2024 'Adapters'), $staging | Out-Null

function Build-Project([string]$project, [string]$output, [string]$framework = '') {
    Write-Host "  构建 $project $framework"
    $arguments = @(
        'build', (Join-Path $root $project),
        '-c', $Configuration,
        ('-p:Version=' + $version),
        '-o', $output,
        '--nologo', '-v', 'q'
    )
    if ($framework) { $arguments += @('-f', $framework) }

    & $dotnet @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "构建失败：$project $framework" }
}

try {
    Build-Project 'src\CadMath.Shell\CadMath.Shell.csproj' (Join-Path $staging 'shell-net8') 'net8.0-windows'
    Build-Project 'src\CadMath.Shell\CadMath.Shell.csproj' (Join-Path $staging 'shell-net48') 'net48'
    Build-Project 'src\CadMath.Adapter.Modern\CadMath.Adapter.Modern.csproj' (Join-Path $staging 'modern')
    Build-Project 'src\CadMath.Adapter.Legacy2024\CadMath.Adapter.Legacy2024.csproj' (Join-Path $staging 'legacy2024')
} catch {
    # -o 与多目标工程不能同时用：多目标时必须指定 -f，所以前面已经分开构建。
    throw
}

# ---- 运行时清单（每个宿主目录一份，只列出自己能用的适配器） ---------------
$allAdapters = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'adapters\adapters.json') | ConvertFrom-Json

function Write-RuntimeManifest([string]$path, [string]$runtimeFilter) {
    $pick = @($allAdapters.adapters | Where-Object { [string]$_.runtime -eq $runtimeFilter })
    if ($pick.Count -eq 0) { throw "没有 runtime=$runtimeFilter 的适配器。" }

    $manifest = [ordered]@{
        schemaVersion = [int]$allAdapters.schemaVersion
        adapters      = $pick
    }
    $json = $manifest | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

Write-RuntimeManifest (Join-Path $win64 'adapters.json') 'net8.0-windows'
Write-RuntimeManifest (Join-Path $win64_2024 'adapters.json') 'net48'

# ---- 组装两个宿主目录 ---------------------------------------------------
$hostFiles = @('CadMath03.dll', 'CadMath.Core.dll', 'CadMath.Abstractions.dll')
foreach ($file in $hostFiles) {
    Copy-Item (Join-Path (Join-Path $staging 'shell-net8') $file) $win64
    Copy-Item (Join-Path (Join-Path $staging 'shell-net48') $file) $win64_2024
}

Copy-Item (Join-Path $staging 'modern\CadMath.Adapter.Modern.dll') (Join-Path $win64 'Adapters')
Copy-Item (Join-Path $staging 'legacy2024\CadMath.Adapter.Legacy2024.dll') (Join-Path $win64_2024 'Adapters')

# ---- PackageContents 与构建信息 ----------------------------------------
function Write-ApplicationPackage([string]$template, [string]$targetFile) {
    $text = Get-Content -Raw -Encoding UTF8 (Join-Path $root $template)
    $text = $text.Replace('__CADMATH_VERSION__', $version)
    [IO.File]::WriteAllText($targetFile, $text, (New-Object Text.UTF8Encoding($false)))
}

Write-ApplicationPackage 'bundle\PackageContents.xml' (Join-Path $bundle 'PackageContents.xml')

# 2024 单独一份 bundle（给 ApplicationPlugins 全局安装用），内容取自 Win64-2024
New-Item -ItemType Directory -Force -Path (Join-Path $bundle2024 'Contents') | Out-Null
Copy-Item -Recurse -Force $win64_2024 (Join-Path $bundle2024 'Contents\Win64-2024')
Write-ApplicationPackage 'bundle\PackageContents-2024.xml' (Join-Path $bundle2024 'PackageContents.xml')

$buildInfo = @"
CadMath03 $version
构建时间: $(Get-Date -Format o)
配置: $Configuration
实验包: $($Experimental.IsPresent)

[2025 / 2026 · .NET 8]  Contents/Win64
  CadMath03.dll            (net8.0-windows, 官方 NuGet 25.1.0 引用)
  Adapters/CadMath.Adapter.Modern.dll

[2024 · .NET Framework 4.8]  Contents/Win64-2024
  CadMath03.dll            (net48, 官方 NuGet 24.3.0 引用)
  Adapters/CadMath.Adapter.Legacy2024.dll
"@
[IO.File]::WriteAllText((Join-Path $bundle 'BUILD-INFO.txt'), $buildInfo, (New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText((Join-Path $bundle2024 'BUILD-INFO.txt'), $buildInfo, (New-Object Text.UTF8Encoding($true)))

# ---- 发行清单 setup.json ------------------------------------------------
$hosts = @(
    [ordered]@{ series = @('R25.0', 'R25.1'); runtime = 'net8.0-windows'; entry = 'Contents/Win64/CadMath03.dll'; bundle = 'CadMath03.bundle' },
    [ordered]@{ series = @('R24.0', 'R24.1', 'R24.2', 'R24.3'); runtime = 'net48'; entry = 'Contents/Win64-2024/CadMath03.dll'; bundle = 'CadMath03-2024.bundle' }
)

$releaseAdapters = @()
foreach ($adapter in @($allAdapters.adapters)) {
    $status = 'built'
    if ($adapter.PSObject.Properties['status'] -and $adapter.status) { $status = [string]$adapter.status }

    if ($Experimental -and $status -eq 'planned') { $status = 'built' }

    $hostDir = if ([string]$adapter.runtime -eq 'net48') { 'Contents/Win64-2024' } else { 'Contents/Win64' }
    $releaseAdapters += [ordered]@{
        id           = [string]$adapter.id
        path         = $hostDir + '/Adapters/' + (Split-Path ([string]$adapter.assembly) -Leaf)
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

$setup = [ordered]@{
    schemaVersion   = 1
    product         = 'CadMath'
    productCode     = '{04913737-F911-4978-9F6B-2DB24F3DCC03}'
    releaseVersion  = $version
    toolVersion     = $version
    experimental    = [bool]$Experimental.IsPresent
    bundleName      = 'CadMath03.bundle'
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
    $name = if ($Experimental) { "CadMath-InlineMath-$version-experimental-2024.zip" } else { "CadMath-InlineMath-$version.zip" }
    $zip = Join-Path $dist $name
    $items = @(
        $bundle,
        $bundle2024,
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
Write-Host '  2025/2026：Contents\Win64（.NET 8）；2024：Contents\Win64-2024（.NET Framework 4.8）。'
