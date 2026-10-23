# CadMath 安装工具 · 共用常量与守卫
# 本文件不修改系统：只有校验、解压、探测与路径加固。
Set-StrictMode -Version 2

$script:ProductCode   = '{04913737-F911-4978-9F6B-2DB24F3DCC03}'
$script:ProductName   = 'CadMath03'
$script:BundleName    = 'CadMath03.bundle'
$script:AssemblyName  = 'CadMath03'
$script:EntryAssembly = 'Contents\Win64\CadMath03.dll'
$script:ConfigFolder  = 'Contents\Win64\adapters.json'

function Get-DefaultStateRoot {
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CadMathInlineMath')
}

function Get-ApplicationsRoot {
    return (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Autodesk\ApplicationPlugins')
}

function Get-CadProcess {
    return @(Get-Process -Name acad,accoreconsole -ErrorAction SilentlyContinue)
}

function Assert-CadClosed {
    $running = @(Get-CadProcess)
    if ($running.Count -eq 0) { return }
    # 只有自动化测试会设这个变量；正式使用时不生效。
    if ($env:CADMATH_SETUP_ALLOW_CAD_RUNNING -eq '1') {
        Write-Warn -Stage 'PRECHECK' ('检测到 {0} 个 AutoCAD 进程，按测试模式继续（不会触碰正在运行的 CAD）。' -f $running.Count)
        return
    }
    throw ('检测到 {0} 个 AutoCAD 进程正在运行。请保存图纸并完全退出 AutoCAD 再重试；本工具不会强制关闭 CAD。' -f $running.Count)
}

function Test-PathWithin {
    param([string]$Path, [string]$Root)
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('找不到文件：{0}' -f $Path) }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { throw ('文件为空：{0}' -f $Path) }
    try { return ($text | ConvertFrom-Json) } catch { throw ('JSON 解析失败：{0}（{1}）' -f $Path, $_.Exception.Message) }
}

function Get-BundleInfo {
    param([Parameter(Mandatory)][string]$Bundle)
    $manifest = Join-Path $Bundle 'PackageContents.xml'
    if (-not (Test-Path -LiteralPath $manifest)) { throw ('包内缺少 PackageContents.xml：{0}' -f $Bundle) }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($manifest, $settings)
    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load($reader)
    } finally { $reader.Dispose() }
    $app = $xml.ApplicationPackage
    if ($app -eq $null) { throw 'PackageContents.xml 缺少 ApplicationPackage 根节点。' }
    if ($app.ProductCode -ne $script:ProductCode -or $app.Name -ne $script:ProductName) {
        throw '这个目录不是 CadMath03 插件包，已停止，未覆盖任何文件。'
    }
    $dll = Join-Path $Bundle $script:EntryAssembly
    if (-not (Test-Path -LiteralPath $dll)) { throw ('包内缺少主程序集：{0}' -f $script:EntryAssembly) }
    $assembly = [Reflection.AssemblyName]::GetAssemblyName($dll)
    if ($assembly.Name -ne $script:AssemblyName) { throw ('主程序集名称不是 {0}。' -f $script:AssemblyName) }
    $assemblyVersion = $assembly.Version.ToString(3)
    if ([version]$app.AppVersion -ne [version]$assemblyVersion) {
        throw ('包内版本不一致：清单 {0}，程序集 {1}。' -f $app.AppVersion, $assemblyVersion)
    }
    return [pscustomobject]@{
        Name        = [string]$app.Name
        Version     = [string]$app.AppVersion
        Bundle      = (Resolve-Path -LiteralPath $Bundle).Path
        Dll         = $dll
        Config      = (Join-Path $Bundle $script:ConfigFolder)
        PayloadRoot = (Resolve-Path -LiteralPath $Bundle).Path
    }
}

function Expand-CadBundleArchive {
    param([string]$Zip, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    $files = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    [long]$total = 0
    try {
        if ($archive.Entries.Count -gt 500) { throw '安装包文件数量异常，已停止。' }
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            $total += $entry.Length
            if ($total -gt 100MB) { throw '安装包解压后体积异常，已停止。' }
            # 拒绝: 绝对路径、驱动器前缀、符号链接条目、越界路径、重复路径
            if ($name -match ':' -or [IO.Path]::IsPathRooted($name)) { throw '安装包包含不安全条目（绝对路径或驱动器前缀）。' }
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw '安装包包含符号链接条目。' }
            $path = [IO.Path]::GetFullPath((Join-Path $root $name))
            if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw '安装包包含越界路径。' }
            if ($seen.ContainsKey($path)) { throw '安装包包含重复路径。' }
            $seen[$path] = $true
            if ($name.EndsWith('\')) {
                New-Item -ItemType Directory -Path $path -Force | Out-Null
                continue
            }
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
            $files.Add($path)
        }
    } finally { $archive.Dispose() }
    return $files.ToArray()
}

function Test-FileSha256 {
    param([string]$Path, [string]$Expected)
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { throw '发行清单里的 SHA-256 格式不正确。' }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected.ToUpperInvariant()) {
        throw ('SHA-256 不匹配，已停止。期望 {0}，实际 {1}' -f $Expected.ToUpperInvariant(), $actual)
    }
    return $actual
}

function Get-ProcessArchitecture {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ([Environment]::Is64BitOperatingSystem) {
        if ($arch -eq 'ARM64') { return 'arm64' }
        return 'x64'
    }
    return 'x86'
}

function Get-OsDescription {
    $caption = '未知'
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $caption = $os.Caption
    } catch { }
    return ('{0}（{1}，{2}）' -f $caption, [Environment]::OSVersion.Version, (Get-ProcessArchitecture))
}

# PS 5.1 陷阱：@($genericList) 会抛 "参数类型不匹配"，因此统一用这个函数把任意输入变成数组。
function ConvertTo-ItemArray {
    param($Value)
    $items = @()
    if ($null -ne $Value) {
        foreach ($entry in $Value) { $items += $entry }
    }
    return ,$items
}