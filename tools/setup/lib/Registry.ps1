# CadMath 安装工具 · 注册表事务
# 只操作 HKCU（或测试注入的假根）。不触碰 SECURELOAD。
Set-StrictMode -Version 2

function Get-RegistrationKey {
    param([string]$ProductPath)
    return (Join-Path $ProductPath 'Applications\CadMathInlineMath')
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

function Get-RegistrationSnapshot {
    param([string]$ProductPath)
    $appKey = Get-RegistrationKey -ProductPath $ProductPath
    $exists = Test-Path -LiteralPath $appKey
    # 用"名称/值/类型"数组而不是哈希表：既能写进 JSON 的事务日志，
    # 又能保证回滚时 DWORD 仍然写回 DWORD，不会被降级成字符串。
    $values = New-Object System.Collections.Generic.List[object]
    if ($exists) {
        $key = Get-Item -LiteralPath $appKey -ErrorAction SilentlyContinue
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
        ProductPath = $ProductPath
        AppKey      = $appKey
        Existed     = $exists
        Values      = $values.ToArray()
        Trusted     = (Get-TrustedPathsEntry -ProductPath $ProductPath)
    }
}

function Restore-RegistrationSnapshot {
    param($Snapshot)
    if ($Snapshot -eq $null) { return }
    $appKey = [string]$Snapshot.AppKey
    if ([string]::IsNullOrWhiteSpace($appKey)) { return }
    if (Test-Path -LiteralPath $appKey) { Remove-Item -LiteralPath $appKey -Recurse -Force }
    if ($Snapshot.Existed) {
        New-Item -Path $appKey -Force | Out-Null
        foreach ($entry in @($Snapshot.Values)) {
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
        [Parameter(Mandatory)][string]$Loader,
        [Parameter(Mandatory)][string[]]$TrustedDirs,
        # 0.5.0：升级时传旧负载的两条路径，写 TRUSTEDPATHS 时顺手换掉，避免一条条累积。
        [string[]]$ReplaceDirs = @()
    )
    $appKey = Get-RegistrationKey -ProductPath $Instance.ProductPath
    if (-not (Test-Path -LiteralPath $appKey)) { New-Item -Path $appKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $appKey -Name 'DESCRIPTION' -Value 'AutoCAD Inline Math' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $appKey -Name 'LOADER' -Value $Loader -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $appKey -Name 'LOADCTRLS' -Value 2 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $appKey -Name 'MANAGED' -Value 1 -PropertyType DWord -Force | Out-Null
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
    return [pscustomobject]@{ AppKey = $appKey; ProfilesUpdated = $touched }
}

function Remove-InstanceRegistration {
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][string[]]$OwnedDirs
    )
    $appKey = Get-RegistrationKey -ProductPath $Instance.ProductPath
    $removedKey = $false
    if (Test-Path -LiteralPath $appKey) {
        Remove-Item -LiteralPath $appKey -Recurse -Force
        $removedKey = $true
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
    return [pscustomobject]@{ RemovedKey = $removedKey; ProfilesUpdated = $touched }
}

function Test-InstanceRegistered {
    param($Instance, [string]$Loader)
    $appKey = Get-RegistrationKey -ProductPath $Instance.ProductPath
    if (-not (Test-Path -LiteralPath $appKey)) { return $false }
    $item = Get-ItemProperty -LiteralPath $appKey -ErrorAction SilentlyContinue
    if ($item -eq $null) { return $false }
    $prop = $item.PSObject.Properties['LOADER']
    if ($prop -eq $null) { return $false }
    return ([string]$prop.Value).Equals($Loader, [StringComparison]::OrdinalIgnoreCase)
}
