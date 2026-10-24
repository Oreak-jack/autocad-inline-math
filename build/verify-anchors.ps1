#requires -Version 5.1
<#
.SYNOPSIS
    核对每个适配器 DLL 实际引用的 AutoCAD 程序集版本，与清单里声明的编译锚一致。

.DESCRIPTION
    为什么需要这一步：docs/VERSION-MATRIX.md 的规则 1 说"每个 band 用 band 内最旧的 SDK 编一份"，
    而这条规则只有在"编出来的二进制确实引用了那个版本"时才成立。
    光看 csproj 不够——MSBuild 可能因为增量构建、传递依赖或版本提升而拿到别的版本。
    所以这里直接读产物 DLL 的 AssemblyRef 表，逐个比对 adapters.json 里声明的 acMgdVersion。

    每个 DLL 都用独立的子进程读取：同一个进程里加载两个同名程序集（不同路径）会失败。
    比对不上就退出码 1，CI 用它当门禁。
#>
[CmdletBinding()]
param(
    [string]$SetupJson,
    # 0.5.0 任务 8：CI 里先用 -Build 跑一遍——没有 dist 时先构建，再看锚对不对。
    [switch]$Build,
    [string]$AcadDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SetupJson)) { $SetupJson = Join-Path $root 'dist\setup.json' }
if ($Build -or -not (Test-Path -LiteralPath $SetupJson)) {
    $buildScript = Join-Path $PSScriptRoot 'build.ps1'
    $buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript)
    if ($AcadDir) { $buildArgs += @('-AcadDir', $AcadDir) }
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "构建失败（退出码 $LASTEXITCODE），无法核对编译锚。" }
}
if (-not (Test-Path -LiteralPath $SetupJson)) { throw "找不到发行清单：$SetupJson（先跑 build\build.ps1）" }

$packageRoot = Split-Path -Parent $SetupJson
$setup = [IO.File]::ReadAllText($SetupJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-AssemblyReference([string]$Path, [string]$Name) {
    $escaped = $Path.Replace("'", "''")
    $command = "`$a = [Reflection.Assembly]::ReflectionOnlyLoadFrom('$escaped'); " +
        "`$r = `$a.GetReferencedAssemblies() | Where-Object { `$_.Name -eq '$Name' } | Select-Object -First 1; " +
        "if (`$r) { Write-Output `$r.Version.ToString() }"
    $output = & $powershell -NoProfile -Command $command 2>&1 | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
    return ($output | Select-Object -First 1)
}

# 清单里的路径都相对于"文件所在的那个 bundle"，先把 host 目录映射回 bundle 名。
$bundleForHostDir = @{}
foreach ($hostEntry in @($setup.hosts)) {
    $entryDir = Split-Path -Parent (([string]$hostEntry.entry) -replace '/', '\')
    if ($entryDir -and -not $bundleForHostDir.ContainsKey($entryDir)) {
        $bundleForHostDir[$entryDir] = [string]$hostEntry.bundle
    }
}

function Resolve-InPackage([string]$RelativePath) {
    $normalized = $RelativePath -replace '/', '\'
    foreach ($dir in $bundleForHostDir.Keys) {
        if ($normalized.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return (Join-Path (Join-Path $packageRoot $bundleForHostDir[$dir]) $normalized)
        }
    }
    return (Join-Path $packageRoot $normalized)
}

$failures = New-Object System.Collections.Generic.List[string]
$checked = 0

Write-Host ''
Write-Host '=== 编译锚核对' -ForegroundColor Cyan
foreach ($adapter in @($setup.adapters)) {
    $expected = [string]$adapter.acMgdVersion
    if ([string]::IsNullOrWhiteSpace($expected)) {
        Write-Host ('  [SKIP] {0}：清单没有声明 acMgdVersion' -f $adapter.id) -ForegroundColor Yellow
        continue
    }

    $dll = Resolve-InPackage ([string]$adapter.path)
    if (-not (Test-Path -LiteralPath $dll)) {
        $failures.Add(('{0}：找不到 {1}' -f $adapter.id, $adapter.path))
        continue
    }

    $actual = Get-AssemblyReference -Path $dll -Name 'acmgd'
    if (-not $actual) {
        $failures.Add(('{0}：读不到 acmgd 引用版本' -f $adapter.id))
        continue
    }

    $checked++
    if ($actual -eq $expected) {
        Write-Host ('  [OK]   {0,-12} acmgd={1}（声明 {2}）' -f $adapter.id, $actual, $expected)
    } else {
        $failures.Add(('{0}：acmgd={1}，但声明 {2}' -f $adapter.id, $actual, $expected))
    }
}

# 宿主本体（CadMath03.dll）也要核对：它决定真正加载哪一个 AutoCAD 引用。
foreach ($hostEntry in @($setup.hosts)) {
    $series = (@($hostEntry.series) -join ',')
    $dll = Resolve-InPackage ([string]$hostEntry.entry)
    if (-not (Test-Path -LiteralPath $dll)) {
        $failures.Add(('宿主 {0}：找不到 {1}' -f $series, $hostEntry.entry))
        continue
    }
    $actual = Get-AssemblyReference -Path $dll -Name 'acmgd'
    $checked++
    $expectedHost = $null
    foreach ($adapter in @($setup.adapters)) {
        if ((@($adapter.path) -join ',') -and ([string]$adapter.path).StartsWith(([string]$hostEntry.entry).Substring(0, ([string]$hostEntry.entry).LastIndexOf('/')), [StringComparison]::OrdinalIgnoreCase)) {
            $expectedHost = [string]$adapter.acMgdVersion
            break
        }
    }
    if (-not $actual) {
        $failures.Add(('宿主 {0}：读不到 acmgd 引用版本' -f $series))
    } elseif ($expectedHost -and $actual -ne $expectedHost) {
        $failures.Add(('宿主 {0}：acmgd={1}，但该宿主下的适配器声明 {2}' -f $series, $actual, $expectedHost))
    } else {
        Write-Host ('  [OK]   宿主 {0,-28} acmgd={1}' -f $series, $actual)
    }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ('编译锚核对失败 {0} 项：' -f $failures.Count) -ForegroundColor Red
    foreach ($item in $failures) { Write-Host ('  - ' + $item) -ForegroundColor Red }
    exit 1
}

Write-Host ('编译锚核对通过：{0} 项' -f $checked) -ForegroundColor Green
exit 0
