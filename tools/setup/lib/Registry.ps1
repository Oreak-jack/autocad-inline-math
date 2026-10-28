# CadMath 安装工具 · 注册表事务
# 只操作 HKCU（或测试注入的假根）。不触碰 SECURELOAD。
#
# 两件产品共用安装器、各自一条注册项：
#   Applications\CadMathInlineMath  -> CadMath03.dll
#   Applications\OreakContextInput  -> Oreak.ContextInput.dll
# 它们各自加载、各自失败：一条注册项写坏不会连累另一条。
Set-StrictMode -Version 2

function Get-RegistrationKey {
    param(
        [Parameter(Mandatory)][string]$ProductPath,
        [string]$AppKey = 'CadMathInlineMath'
    )
    return (Join-Path $ProductPath ('Applications\' + $AppKey))
}

function Get-ProfileKeys {
    param([string]$ProductPath)
    $profiles = Join-Path $ProductPath 'Profiles'
    if (-not (Test-Path -LiteralPath $profiles)) { return @() }
    return @(Get-ChildItem -LiteralPath $profiles -ErrorAction SilentlyContinue)
}

function Get-TrustedPathsEntry {
    param([string]$ProductPath)
    # 返回每个 Profile 的 TRUSTEDPATHS 现状（用于快照与精确回滚）。
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($profile in Get-ProfileKeys -ProductPath $ProductPath) {
        $variables = Join-Path $profile.PSPath 'Variables'
        if (-not (Test-Path -LiteralPath $variables)) { continue }
        $item = Get-ItemProperty -LiteralPath $variables -ErrorAction SilentlyContinue
        if ($item -eq $null) { continue }
        $prop = $item.PSObject.Properties['TRUSTEDPATHS']
        $value = $null
        if ($prop -ne $null) { $value = [string]$prop.Value }
        $entries.Add([pscustomobject]@{
            ProfileKey    = $profile.PSPath
            VariablesKey  = $variables
            Value         = $value
            Existed       = ($prop -ne $null)
        })
    }
    return $entries.ToArray()
}

function Get-SingleKeySnapshot {
    param([string]$AppKey)
    $exists = Test-Path -LiteralPath $AppKey
    # 用"名称/值/类型"数组而不是哈希表：既能写进 JSON 的事务日志，
    # 又能保证回滚时 DWORD 仍然写回 DWORD，不会被降级成字符串。
    $values = New-Object System.Collections.Generic.List[object]
    if ($exists) {
        $key = Get-Item -LiteralPath $AppKey -ErrorAction SilentlyContinue
        if ($key -ne $null) {
            foreach ($name in $key.GetValueNames()) {
                $values.Add([pscustomobject]@{
                    Name  = $name
                    Value = $key.GetValue($name)
                    Kind  = $key.GetValueKind($name).ToString()
                })
            }
        }
    }
    return [pscustomobject]@{
        AppKey  = $AppKey
        Existed = $exists
        Values  = $values.ToArray()
    }
}

function Get-RegistrationSnapshot {
    param(
        [Parameter(Mandatory)][string]$ProductPath,
        [string[]]$AppKeys = @('CadMathInlineMath', 'OreakContextInput')
    )
    $keys = New-Object System.Collections.Generic.List[object]
    foreach ($appKey in $AppKeys) {
        $keys.Add((Get-SingleKeySnapshot -AppKey (Get-RegistrationKey -ProductPath $ProductPath -AppKey $appKey)))
    }
    return [pscustomobject]@{
        ProductPath = $ProductPath
        Keys        = $keys.ToArray()
        Trusted     = (Get-TrustedPathsEntry -ProductPath $ProductPath)
    }
}

function Restore-SingleKey {
    param($Key)
    if ($Key -eq $null) { return }
    $appKey = [string]$Key.PSObject.Properties['AppKey'].Value
    if ([string]::IsNullOrWhiteSpace($appKey)) { return }
    if (Test-Path -LiteralPath $appKey) { Remove-Item -LiteralPath $appKey -Recurse -Force }
    if (-not $Key.Existed) { return }
    New-Item -Path $appKey -Force | Out-Null
    foreach ($entry in @($Key.Values)) {
        if ($entry -eq $null) { continue }
        $name = [string]$entry.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $kind = 'String'
        if ($entry.PSObject.Properties['Kind'] -and $entry.Kind) { $kind = [string]$entry.Kind }
        $value = $entry.Value
        if ($kind -eq 'DWord') { $value = [int]$value }
        elseif ($kind -eq 'QWord') { $value = [long]$value }
        elseif ($kind -eq 'MultiString') { $value = [string[]]@($value) }
        else { $value = [string]$value }
        New-ItemProperty -LiteralPath $appKey -Name $name -Value $value -PropertyType $kind -Force | Out-Null
    }
}

function Restore-RegistrationSnapshot {
    param($Snapshot)
    if ($Snapshot -eq $null) { return }
    # 兼容旧事务日志（只有 AppKey + Values）。
    if ($Snapshot.PSObject.Properties['Keys'] -and $Snapshot.Keys) {
        foreach ($key in @($Snapshot.Keys)) { Restore-SingleKey -Key $key }
    } else {
        $legacy = [pscustomobject]@{
            AppKey  = [string]$Snapshot.AppKey
            Existed = [bool]$Snapshot.Existed
            Values  = @($Snapshot.Values)
        }
        Restore-SingleKey -Key $legacy
    }

    foreach ($entry in @($Snapshot.Trusted)) {
        if ($entry -eq $null) { continue }
        $variables = [string]$entry.VariablesKey
        if ([string]::IsNullOrWhiteSpace($variables)) { continue }
        if (-not (Test-Path -LiteralPath $variables)) { continue }
        if ($entry.Existed) {
            New-ItemProperty -LiteralPath $variables -Name 'TRUSTEDPATHS' -Value ([string]$entry.Value) -PropertyType String -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $variables -Name 'TRUSTEDPATHS' -ErrorAction SilentlyContinue
        }
    }
}

function Join-TrustedPath {
    param([string]$Current, [string[]]$Add)
    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Current)) {
        foreach ($piece in $Current.Split(';')) {
            if (-not [string]::IsNullOrWhiteSpace($piece)) { $parts.Add($piece.Trim()) }
        }
    }
    foreach ($item in $Add) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $normalized = $item.TrimEnd('\')
        $present = $false
        foreach ($existing in $parts) {
            if ($existing.TrimEnd('\').Equals($normalized, [StringComparison]::OrdinalIgnoreCase)) { $present = $true; break }
        }
        if (-not $present) { $parts.Add($normalized) }
    }
    return ($parts -join ';')
}

function Remove-TrustedPath {
    param([string]$Current, [string[]]$Remove)
    if ([string]::IsNullOrWhiteSpace($Current)) { return $Current }
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($piece in $Current.Split(';')) {
        if ([string]::IsNullOrWhiteSpace($piece)) { continue }
        $trimmed = $piece.Trim()
        $drop = $false
        foreach ($item in $Remove) {
            if ([string]::IsNullOrWhiteSpace($item)) { continue }
            if ($trimmed.TrimEnd('\').Equals($item.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { $drop = $true; break }
        }
        if (-not $drop) { $keep.Add($trimmed) }
    }
    return ($keep -join ';')
}

function Set-InstanceRegistration {
    param(
        [Parameter(Mandatory)]$Instance,
        # 每项：{ Id, AppKey, Loader, Description }。逐个写，互不影响。
        [Parameter(Mandatory)][object[]]$Products,
        [Parameter(Mandatory)][string[]]$TrustedDirs,
        # 0.5.0：升级时传旧负载的两条路径，写 TRUSTEDPATHS 时顺手换掉，避免一条条累积。
        [string[]]$ReplaceDirs = @()
    )
    $registered = New-Object System.Collections.Generic.List[object]
    $failures = New-Object System.Collections.Generic.List[object]
    foreach ($product in $Products) {
        $appKey = Get-RegistrationKey -ProductPath $Instance.ProductPath -AppKey ([string]$product.AppKey)
        try {
            if (-not (Test-Path -LiteralPath $appKey)) { New-Item -Path $appKey -Force | Out-Null }
            New-ItemProperty -LiteralPath $appKey -Name 'DESCRIPTION' -Value ([string]$product.Description) -PropertyType String -Force | Out-Null
            New-ItemProperty -LiteralPath $appKey -Name 'LOADER' -Value ([string]$product.Loader) -PropertyType String -Force | Out-Null
            New-ItemProperty -LiteralPath $appKey -Name 'LOADCTRLS' -Value 2 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -LiteralPath $appKey -Name 'MANAGED' -Value 1 -PropertyType DWord -Force | Out-Null
            $registered.Add([string]$product.Id)
        } catch {
            $failures.Add([pscustomobject]@{ Id = [string]$product.Id; Error = $_.Exception.Message })
        }
    }

    $touched = 0
    foreach ($entry in @(Get-TrustedPathsEntry -ProductPath $Instance.ProductPath)) {
        if (-not (Test-Path -LiteralPath $entry.VariablesKey)) { continue }
        $current = $entry.Value
        if ($ReplaceDirs.Count -gt 0) { $current = Remove-TrustedPath -Current $current -Remove $ReplaceDirs }
        $merged = Join-TrustedPath -Current $current -Add $TrustedDirs
        if ($merged -ne $entry.Value) {
            New-ItemProperty -LiteralPath $entry.VariablesKey -Name 'TRUSTEDPATHS' -Value $merged -PropertyType String -Force | Out-Null
            $touched++
        }
    }
    return [pscustomobject]@{ Registered = $registered.ToArray(); Failures = $failures.ToArray(); ProfilesUpdated = $touched }
}

function Remove-InstanceRegistration {
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][object[]]$Products,
        [Parameter(Mandatory)][string[]]$OwnedDirs
    )
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($product in $Products) {
        $appKey = Get-RegistrationKey -ProductPath $Instance.ProductPath -AppKey ([string]$product.AppKey)
        if (Test-Path -LiteralPath $appKey) {
            Remove-Item -LiteralPath $appKey -Recurse -Force
            $removed.Add([string]$product.Id)
        }
    }
    $touched = 0
    foreach ($entry in @(Get-TrustedPathsEntry -ProductPath $Instance.ProductPath)) {
        if (-not (Test-Path -LiteralPath $entry.VariablesKey)) { continue }
        $stripped = Remove-TrustedPath -Current $entry.Value -Remove $OwnedDirs
        if ($stripped -ne $entry.Value) {
            if ([string]::IsNullOrWhiteSpace($stripped)) {
                Remove-ItemProperty -LiteralPath $entry.VariablesKey -Name 'TRUSTEDPATHS' -ErrorAction SilentlyContinue
            } else {
                New-ItemProperty -LiteralPath $entry.VariablesKey -Name 'TRUSTEDPATHS' -Value $stripped -PropertyType String -Force | Out-Null
            }
            $touched++
        }
    }
    return [pscustomobject]@{ Removed = $removed.ToArray(); ProfilesUpdated = $touched }
}

function Test-InstanceRegistered {
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][object[]]$Products
    )
    foreach ($product in $Products) {
        $appKey = Get-RegistrationKey -ProductPath $Instance.ProductPath -AppKey ([string]$product.AppKey)
        if (-not (Test-Path -LiteralPath $appKey)) { return $false }
        $item = Get-ItemProperty -LiteralPath $appKey -ErrorAction SilentlyContinue
        if ($item -eq $null) { return $false }
        $prop = $item.PSObject.Properties['LOADER']
        if ($prop -eq $null) { return $false }
        if (-not ([string]$prop.Value).Equals([string]$product.Loader, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}
