# CadMath 安装工具 · 清单与匹配
# 运行时清单 adapters.json 由 Shell 读取；发行清单 setup.json 由本工具读取。
Set-StrictMode -Version 2

$script:AllStatuses = @('planned', 'built', 'automated-tested', 'host-tested', 'released', 'disabled')
$script:InstallableStatuses = @('built', 'automated-tested', 'host-tested', 'released')

function Read-SetupManifest {
    param([Parameter(Mandatory)][string]$Path)
    $doc = Read-JsonFile -Path $Path
    if ($doc.PSObject.Properties['schemaVersion'] -eq $null -or [int]$doc.schemaVersion -ne 1) {
        throw '发行清单的 schemaVersion 不受支持（需要 1）。'
    }
    if ($doc.product -ne 'CadMath') { throw '发行清单的 product 不是 CadMath。' }
    if ([string]$doc.releaseVersion -notmatch '^\d+\.\d+\.\d+$') { throw '发行清单的 releaseVersion 不合法。' }
    if ($doc.zip -eq $null -or -not $doc.zip.name) { throw '发行清单缺少 zip.name。' }
    if ($doc.files -ne $null) {
        foreach ($file in @($doc.files)) {
            if (-not $file.path) { throw '发行清单的 files 条目缺少 path。' }
            if ([string]$file.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw ('发行清单里 {0} 的 sha256 不合法。' -f $file.path) }
        }
    }
    if ($doc.adapters -eq $null -or @($doc.adapters).Count -eq 0) { throw '发行清单没有任何适配器。' }
    $ids = @{}
    foreach ($adapter in @($doc.adapters)) {
        foreach ($field in @('id', 'path', 'cadSeries', 'status', 'runtime')) {
            if ($adapter.PSObject.Properties[$field] -eq $null -or [string]::IsNullOrWhiteSpace([string]$adapter.$field)) {
                throw ('适配器缺少字段 {0}。' -f $field)
            }
        }
        if ($ids.ContainsKey($adapter.id)) { throw ('发行清单里适配器 id 重复：{0}' -f $adapter.id) }
        $ids[$adapter.id] = $true
        if ($script:AllStatuses -notcontains $adapter.status) {
            throw ('适配器 {0} 的 status 不受支持：{1}' -f $adapter.id, $adapter.status)
        }
        if (@($adapter.cadSeries).Count -eq 0) { throw ('适配器 {0} 没有 cadSeries。' -f $adapter.id) }
        if ($adapter.PSObject.Properties['buildRange'] -and $adapter.buildRange -ne $null) {
            $min = $adapter.buildRange.min
            $max = $adapter.buildRange.max
            if ($min -and $min -match 'REPLACE_') { throw ('适配器 {0} 的 buildRange.min 还是占位符。' -f $adapter.id) }
            if ($max -and $max -match 'REPLACE_') { throw ('适配器 {0} 的 buildRange.max 还是占位符。' -f $adapter.id) }
        }
    }
    return $doc
}

function Read-RuntimeManifest {
    param([Parameter(Mandatory)][string]$Path)
    $doc = Read-JsonFile -Path $Path
    if ($doc.PSObject.Properties['schemaVersion'] -eq $null -or [int]$doc.schemaVersion -ne 1) {
        throw '运行时清单的 schemaVersion 不受支持（需要 1）。'
    }
    if ($doc.adapters -eq $null -or @($doc.adapters).Count -eq 0) { throw '运行时清单没有任何适配器。' }
    return $doc
}

function Test-BuildInRange {
    param([string]$Build, $Range)
    if ($Range -eq $null -or [string]::IsNullOrWhiteSpace($Build)) { return $true }
    try { $current = [version]$Build } catch { return $false }
    if ($Range.min) {
        try { if ($current -lt [version]$Range.min) { return $false } } catch { return $false }
    }
    if ($Range.max) {
        try { if ($current -gt [version]$Range.max) { return $false } } catch { return $false }
    }
    return $true
}

function Select-AdapterForInstance {
    param(
        [Parameter(Mandatory)]$Setup,
        [Parameter(Mandatory)]$Instance,
        [string]$Architecture = 'x64'
    )
    $matched = New-Object System.Collections.Generic.List[object]
    $rejected = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in @($Setup.adapters)) {
        $reason = $null
        $detail = $null
        if (@($adapter.cadSeries) -notcontains $Instance.Series) {
            $reason = 'series-mismatch'
            $detail = ('需要 {0}，实例是 {1}' -f (@($adapter.cadSeries) -join '/'), $Instance.Series)
        } elseif ($script:InstallableStatuses -notcontains $adapter.status) {
            $reason = 'status-' + $adapter.status
            $detail = ('状态 {0} 不允许安装' -f $adapter.status)
        } elseif ($adapter.PSObject.Properties['architecture'] -and $adapter.architecture -and $adapter.architecture -ne $Architecture) {
            $reason = 'architecture-mismatch'
            $detail = ('需要 {0}，本机是 {1}' -f $adapter.architecture, $Architecture)
        } elseif ($adapter.PSObject.Properties['buildRange'] -and $adapter.buildRange -ne $null) {
            if (-not $Instance.BuildKnown) {
                $reason = 'build-unknown'
                $detail = '无法读取 CAD 构建版本，不能确认在 buildRange 内'
            } elseif (-not (Test-BuildInRange -Build $Instance.Build -Range $adapter.buildRange)) {
                $reason = 'build-out-of-range'
                $detail = ('构建 {0} 不在 {1} ~ {2} 内' -f $Instance.Build, $adapter.buildRange.min, $adapter.buildRange.max)
            }
        }
        if ($reason) {
            $rejected.Add([pscustomobject]@{ AdapterId = $adapter.id; Reason = $reason; Detail = $detail })
        } else {
            $matched.Add($adapter)
        }
    }
    if ($matched.Count -eq 1) {
        return [pscustomobject]@{ Status = 'matched'; Adapter = $matched[0]; Rejections = $rejected.ToArray() }
    }
    if ($matched.Count -gt 1) {
        $ids = @($matched | ForEach-Object { $_.id }) -join ', '
        return [pscustomobject]@{
            Status     = 'ambiguous'
            Adapter    = $null
            Rejections = $rejected.ToArray()
            Error      = ('有多个适配器同样匹配：{0}。请人工确认后再安装。' -f $ids)
        }
    }
    return [pscustomobject]@{ Status = 'none'; Adapter = $null; Rejections = $rejected.ToArray() }
}

function Get-RejectionSummary {
    param($Rejections)
    if ($Rejections -eq $null -or @($Rejections).Count -eq 0) { return '无可用适配器（清单里没有针对该版本）' }
    return (@($Rejections) | ForEach-Object { '{0}:{1}' -f $_.AdapterId, $_.Reason }) -join '; '
}
