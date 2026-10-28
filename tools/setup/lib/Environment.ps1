# CadMath 安装工具 · 环境扫描（只读）
# 扫描结果只用于展示与匹配，不触发安装、不写注册表。
Set-StrictMode -Version 2

function Get-ReleaseYear {
    param([string]$Release)
    $map = @{
        'R25.1' = '2026'; 'R25.0' = '2025'; 'R24.3' = '2024'; 'R24.2' = '2023'
        'R24.1' = '2022'; 'R24.0' = '2021'; 'R23.1' = '2020'; 'R23.0' = '2019'
        'R22.0' = '2018'; 'R21.0' = '2017'
    }
    if ($map.ContainsKey($Release)) { return $map[$Release] }
    return $null
}

function Get-ReleaseSeries {
    param([string]$Release)
    # 清单里的 cadSeries 用的是带 R 的写法（R25.1），这里保持一致。
    if ($Release -match '^R\d+\.\d+$') { return $Release }
    return $null
}

function Get-MachineValue {
    param([string]$Root, [string]$Release, [string]$Product, [string]$Name)
    # 真实 HKLM 优先用 64 位视图，失败再退回 32 位；测试用假根直接读。
    if ($Root -like 'HKLM:*') {
        $relative = 'SOFTWARE\Autodesk\AutoCAD\{0}\{1}' -f $Release, $Product
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
            $base = $null
            $key = $null
            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
                $key = $base.OpenSubKey($relative, $false)
            } catch {
                $key = $null
            }
            if ($key -ne $null) {
                try {
                    $value = $key.GetValue($Name)
                } finally { $key.Dispose() }
                if ($value -ne $null -and "$value" -ne '') {
                    if ($base -ne $null) { $base.Dispose() }
                    return [string]$value
                }
            }
            if ($base -ne $null) { $base.Dispose() }
        }
        return $null
    }
    $path = Join-Path (Join-Path $Root $Release) $Product
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    if ($item -eq $null) { return $null }
    $prop = $item.PSObject.Properties[$Name]
    if ($prop -eq $null) { return $null }
    return [string]$prop.Value
}

function Get-CadBuildInfo {
    param([string]$Location)
    $result = [pscustomobject]@{ Build = $null; BuildKnown = $false; Source = $null }
    if ([string]::IsNullOrWhiteSpace($Location)) { return $result }
    if (-not (Test-Path -LiteralPath $Location)) { return $result }
    foreach ($candidate in @('acmgd.dll', 'accoremgd.dll', 'acad.exe')) {
        $file = Join-Path $Location $candidate
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($file)
            # 文件版本里的数字最可靠：acad.exe 带 R 前缀，acmgd 是 25.1.60.0。
            $raw = $info.FileVersionRaw
            if ($raw -ne $null -and $raw.Major -gt 0) {
                $result.Build = '{0}.{1}.{2}.{3}' -f $raw.Major, $raw.Minor, $raw.Build, $raw.Revision
                $result.BuildKnown = $true
                $result.Source = $candidate
                return $result
            }
            foreach ($text in @($info.ProductVersion, $info.FileVersion)) {
                if ([string]::IsNullOrWhiteSpace($text)) { continue }
                if ($text -match '^[Rr]?(\d+(\.\d+){1,4})$') {
                    $result.Build = $Matches[1]
                    $result.BuildKnown = $true
                    $result.Source = $candidate
                    return $result
                }
            }
        } catch { }
    }
    return $result
}

function Get-InstancePluginState {
    param([string]$ProductPath)
    $result = [pscustomobject]@{
        State         = 'none'
        Loader        = $null
        PathExists    = $false
        Version       = $null
        # 第二件产品（语境切换）独立一条注册项，单独探测，互不影响。
        ModuleState   = 'none'
        ModuleLoader  = $null
        ModuleVersion = $null
    }
    foreach ($pair in @(@('Applications\CadMathInlineMath', 'main'), @('Applications\OreakContextInput', 'module'))) {
        $candidate = Join-Path $ProductPath $pair[0]
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $entry = Get-ItemProperty -LiteralPath $candidate -ErrorAction SilentlyContinue
        if ($entry -eq $null) { continue }
        $loaderProp = $entry.PSObject.Properties['LOADER']
        if ($loaderProp -eq $null) { continue }
        $loaderValue = [string]$loaderProp.Value
        $version = $null
        $pathOk = $false
        if ($loaderValue -and (Test-Path -LiteralPath $loaderValue)) {
            $pathOk = $true
            try { $version = [Reflection.AssemblyName]::GetAssemblyName($loaderValue).Version.ToString(3) } catch { }
        }
        if ($pair[1] -eq 'module') {
            $result.ModuleState = 'registry'
            $result.ModuleLoader = $loaderValue
            $result.ModuleVersion = $version
        } else {
            $result.State = 'registry'
            $result.Loader = $loaderValue
            $result.PathExists = $pathOk
            $result.Version = $version
        }
    }
    return $result
}

function Get-LegacyBundleInfo {
    param([string]$AppsRoot)
    $bundle = Join-Path $AppsRoot 'CadMath03.bundle'
    $result = [pscustomobject]@{ Present = $false; Path = $bundle; Version = $null; Health = 'absent' }
    if (-not (Test-Path -LiteralPath $bundle)) { return $result }
    $result.Present = $true
    try {
        $info = Get-BundleInfo -Bundle $bundle
        $result.Version = $info.Version
        $result.Health = 'ok'
    } catch {
        $result.Health = 'broken'
    }
    return $result
}

function Invoke-EnvironmentScan {
    param(
        [string]$RegistryRoot = 'HKCU:\Software\Autodesk\AutoCAD',
        [string]$MachineRegistryRoot = 'HKLM:\SOFTWARE\Autodesk\AutoCAD',
        [string]$AppsRoot = (Get-ApplicationsRoot),
        [string]$StateRoot = (Get-DefaultStateRoot)
    )
    $instances = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $RegistryRoot) {
        foreach ($releaseKey in @(Get-ChildItem -LiteralPath $RegistryRoot -ErrorAction SilentlyContinue)) {
            $release = $releaseKey.PSChildName
            if ($release -notmatch '^R\d+\.\d+$') { continue }
            foreach ($productKey in @(Get-ChildItem -LiteralPath $releaseKey.PSPath -ErrorAction SilentlyContinue)) {
                $product = $productKey.PSChildName
                if ($product -notmatch '^ACAD-[0-9A-Fa-f]+:[0-9A-Fa-f]+$') { continue }
                $location = Get-MachineValue -Root $MachineRegistryRoot -Release $release -Product $product -Name 'AcadLocation'
                $machineName = Get-MachineValue -Root $MachineRegistryRoot -Release $release -Product $product -Name 'ProductName'
                $build = Get-CadBuildInfo -Location $location
                $plugin = Get-InstancePluginState -ProductPath $productKey.PSPath
                $year = Get-ReleaseYear -Release $release
                $label = $null
                if ($machineName) { $label = $machineName }
                elseif ($year) { $label = 'AutoCAD ' + $year }
                else { $label = 'AutoCAD（' + $release + '）' }
                $instances.Add([pscustomobject]@{
                    Id             = ('{0}\{1}' -f $release, $product)
                    Release        = $release
                    Series         = (Get-ReleaseSeries -Release $release)
                    Year           = $year
                    Label          = $label
                    ProductName    = $machineName
                    ProductPath    = $productKey.PSPath
                    AcadLocation   = $location
                    Build          = $build.Build
                    BuildKnown     = $build.BuildKnown
                    BuildSource    = $build.Source
                    PluginState    = $plugin.State
                    PluginLoader   = $plugin.Loader
                    PluginPathOk   = $plugin.PathExists
                    PluginVersion  = $plugin.Version
        ModuleState    = $plugin.ModuleState
        ModuleLoader   = $plugin.ModuleLoader
        ModuleVersion  = $plugin.ModuleVersion
                    LegacyBundle   = $false
                })
            }
        }
    }
    $legacy = Get-LegacyBundleInfo -AppsRoot $AppsRoot
    if ($legacy.Present) {
        foreach ($instance in $instances) {
            $instance.LegacyBundle = $true
            if ($instance.PluginState -eq 'none') { $instance.PluginState = 'bundle' }
            elseif ($instance.PluginState -eq 'registry') { $instance.PluginState = 'both' }
        }
    }
    $report = [pscustomobject]@{
        Os               = (Get-OsDescription)
        Architecture     = (Get-ProcessArchitecture)
        Instances        = $instances.ToArray()
        LegacyBundle     = $legacy
        StateRoot        = $StateRoot
        CadRunning       = (@(Get-CadProcess).Count -gt 0)
        CadProcessCount  = @(Get-CadProcess).Count
    }
    return $report
}
