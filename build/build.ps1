#requires -Version 5.1
<#
.SYNOPSIS
    构建 CadMath03.bundle（无需安装器的分发包）。

.DESCRIPTION
    1. 从 Directory.Build.props 读取唯一版本号；
    2. 编译 Shell 与两个适配器；
    3. 组装 bundle 目录结构，并把版本写进 PackageContents.xml；
    4. 可选打成 zip。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\build.ps1 -AcadDir "D:\AutoCAD 2026"

    # 只组装、不打 zip
    powershell -ExecutionPolicy Bypass -File build\build.ps1 -AcadDir "D:\AutoCAD 2026" -NoZip
#>
[CmdletBinding()]
param(
    [string]$AcadDir = $env:ACAD_REFERENCE_DIR,
    [string]$Configuration = 'Release',
    [switch]$NoZip
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

    throw '找不到带 SDK 的 dotnet。请安装 .NET 8 SDK。'
}

$dotnet = Resolve-Dotnet

if ([string]::IsNullOrWhiteSpace($AcadDir)) {
    $AcadDir = 'C:\Program Files\Autodesk\AutoCAD 2026'
}
if (-not (Test-Path (Join-Path $AcadDir 'acmgd.dll'))) {
    throw "AcadDir 里没有 acmgd.dll：$AcadDir 。请用 -AcadDir 指定 AutoCAD 安装目录。"
}

# ---- 版本单一来源 -------------------------------------------------------
[xml]$props = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Directory.Build.props')
$version = $props.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
if (-not $version) { throw 'Directory.Build.props 里没有 <Version>。' }

$dist = Join-Path $root 'dist'
$bundle = Join-Path $dist 'CadMath03.bundle'
$win64 = Join-Path $bundle 'Contents\Win64'
$adapterDir = Join-Path $win64 'Adapters'
$staging = Join-Path $root 'objs\publish'

Write-Host "CadMath $version  |  AutoCAD 引用: $AcadDir  |  $Configuration"

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $win64, $adapterDir, $staging | Out-Null

function Build-Project([string]$project, [string]$output) {
    Write-Host "  构建 $project"
    & $dotnet build (Join-Path $root $project) `
        -c $Configuration `
        -p:AcadDir="$AcadDir" `
        -p:Version="$version" `
        -o "$output" `
        --nologo -v q | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "构建失败：$project" }
}

Build-Project 'src\CadMath.Shell\CadMath.Shell.csproj' (Join-Path $staging 'shell')
Build-Project 'src\CadMath.Adapter.Modern\CadMath.Adapter.Modern.csproj' (Join-Path $staging 'modern')
Build-Project 'src\CadMath.Adapter.Legacy\CadMath.Adapter.Legacy.csproj' (Join-Path $staging 'legacy')

# ---- 组装 bundle --------------------------------------------------------
$required = @('CadMath03.dll', 'CadMath.Core.dll', 'CadMath.Abstractions.dll', 'adapters.json')
foreach ($file in $required) {
    $source = Join-Path (Join-Path $staging 'shell') $file
    if (-not (Test-Path $source)) { throw "Shell 输出缺少 $file" }
    Copy-Item $source $win64
}

Copy-Item (Join-Path $staging 'modern\CadMath.Adapter.Modern.dll') $adapterDir
Copy-Item (Join-Path $staging 'legacy\CadMath.Adapter.Legacy.dll') $adapterDir

$manifest = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'bundle\PackageContents.xml')
$manifest = $manifest.Replace('__CADMATH_VERSION__', $version)
Set-Content -Path (Join-Path $bundle 'PackageContents.xml') -Value $manifest -Encoding UTF8 -NoNewline

$acmgdVersion = (Get-Item (Join-Path $AcadDir 'acmgd.dll')).VersionInfo.FileVersion
@"
CadMath03 $version
构建时间: $(Get-Date -Format o)
AutoCAD 引用目录: $AcadDir
acmgd 文件版本: $acmgdVersion
配置: $Configuration
适配器: $(Get-ChildItem $adapterDir -Filter *.dll | ForEach-Object { $_.Name }) 
"@ | Set-Content -Path (Join-Path $bundle 'BUILD-INFO.txt') -Encoding UTF8

Write-Host ''
Get-ChildItem $bundle -Recurse -File | ForEach-Object { '  ' + $_.FullName.Substring($bundle.Length + 1) }

if (-not $NoZip) {
    $zip = Join-Path $dist ("CadMath-InlineMath-$version.zip")
    Compress-Archive -Path $bundle -DestinationPath $zip -Force
    Write-Host "`n  打包: $zip"
}

Write-Host "`n完成。把 CadMath03.bundle 复制到 %APPDATA%\Autodesk\ApplicationPlugins\ 后重启 CAD。"
