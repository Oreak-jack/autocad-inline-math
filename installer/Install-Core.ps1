# Windows PowerShell 5.1. No UI or machine changes when dot-sourced.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:Repo = 'Oreak-jack/autocad-inline-math'
$script:ProductCode = '{04913737-F911-4978-9F6B-2DB24F3DCC03}'

function Get-CadProducts([string]$Root = 'HKCU:\Software\Autodesk\AutoCAD') {
    foreach ($release in @('R25.0','R25.1')) {
        $key = Join-Path $Root $release
        if (Test-Path -LiteralPath $key) {
            Get-ChildItem -LiteralPath $key | Where-Object { $_.PSChildName -match '^ACAD-[0-9A-F]+:[0-9A-F]+$' } | ForEach-Object { $_.PSPath }
        }
    }
}
function Assert-CadClosed {
    if (Get-Process -Name acad,accoreconsole -ErrorAction SilentlyContinue) {
        throw '请保存图纸并关闭所有 AutoCAD 窗口，再点击安装。安装器不会强制关闭 CAD。'
    }
}
function Get-BundleInfo([string]$Bundle) {
    $manifest = Join-Path $Bundle 'PackageContents.xml'
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($manifest,$settings)
    try { $xml = New-Object System.Xml.XmlDocument; $xml.XmlResolver = $null; $xml.Load($reader) } finally { $reader.Dispose() }
    $app = $xml.ApplicationPackage
    if ($app.ProductCode -ne $script:ProductCode -or $app.Name -ne 'CadMath03') { throw '目录不是本插件，未覆盖任何文件。' }
    $dll = Join-Path $Bundle 'Contents\Win64\CadMath03.dll'
    $assembly = [Reflection.AssemblyName]::GetAssemblyName($dll)
    if ($assembly.Name -ne 'CadMath03' -or [version]$app.AppVersion -ne [version]($assembly.Version.ToString(3))) { throw 'DLL 与安装包版本不一致。' }
    return [pscustomobject]@{ Version = $app.AppVersion; Dll = $dll }
}
function Get-InstallTarget([string]$Parent) {
    if (-not [IO.Path]::IsPathRooted($Parent) -or $Parent.StartsWith('\\') -or $Parent -match '[;*?]') { throw '请选择本机磁盘上的文件夹，路径不能含分号或通配符。' }
    $full = [IO.Path]::GetFullPath($Parent)
    if ($full -ne [IO.Path]::GetPathRoot($full)) { $full=$full.TrimEnd('\') }
    if ([IO.Path]::GetFileName($full) -eq 'CadMath03.bundle') { throw '请选择插件的上级目录，不要选 CadMath03.bundle 文件夹本身。' }
    # Never traverse an existing junction/symlink when replacing directories.
    $check = Join-Path $full 'CadMath03.bundle'
    while ($check) {
        if ((Test-Path -LiteralPath $check) -and ((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '安装路径含链接或联接，请选择普通文件夹。' }
        $check = [IO.Path]::GetDirectoryName($check)
    }
    return Join-Path $full 'CadMath03.bundle'
}
function Expand-CadArchive([string]$Zip,[string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    $seen = @{}; [long]$total = 0
    try {
        if ($archive.Entries.Count -gt 200) { throw '安装包文件数量异常。' }
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('/','\')
            $total += $entry.Length
            if ($total -gt 50MB -or $name -match ':' -or [IO.Path]::IsPathRooted($name) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw '安装包包含不安全的文件。' }
            $path = [IO.Path]::GetFullPath((Join-Path $root $name))
            if (-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($path)) { throw '安装包包含越界或重复路径。' }
            $seen[$path] = $true
            if ($name.EndsWith('\')) { New-Item -ItemType Directory -Path $path -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path,$false)
        }
    } finally { $archive.Dispose() }
}
function Test-ArchiveHash([string]$Zip,[string]$Checksums,[string]$AssetName) {
    $pattern = '(?im)^([0-9a-f]{64})\s+\*?' + [regex]::Escape($AssetName) + '\s*$'
    $matchesFound = [regex]::Matches($Checksums,$pattern)
    if ($matchesFound.Count -ne 1 -or (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash -ne $matchesFound[0].Groups[1].Value) { throw '安装包校验失败，未安装。请重新下载。' }
}
function Get-CadRelease([string]$Cache,[scriptblock]$Progress = {}) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'AutoCAD-Inline-Math-Installer'; Accept = 'application/vnd.github+json' }
    & $Progress '正在查询 GitHub 最新正式版本…'
    $release = Invoke-RestMethod "https://api.github.com/repos/$script:Repo/releases/latest" -Headers $headers -TimeoutSec 30
    if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') { throw '没有可用的正式安装包。' }
    $version = $matches[1]
    $assetName = "AutoCAD-Inline-Math-v$version.zip"
    $zipAsset = @($release.assets | Where-Object { $_.name -eq $assetName })
    $sumAsset = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' })
    if ($zipAsset.Count -ne 1 -or $sumAsset.Count -ne 1 -or $zipAsset[0].size -gt 20MB -or $sumAsset[0].size -gt 64KB) { throw '发布页缺少合适的安装包或校验文件。' }
    New-Item -ItemType Directory -Path $Cache -Force | Out-Null
    foreach ($asset in @($zipAsset[0],$sumAsset[0])) {
        $expected = "https://github.com/$script:Repo/releases/download/v$version/$($asset.name)"
        if ($asset.browser_download_url -cne $expected) { throw '下载来源与官方仓库不一致。' }
        & $Progress ('正在下载 '+$asset.name+'…')
        Invoke-WebRequest $expected -Headers $headers -UseBasicParsing -TimeoutSec 90 -OutFile (Join-Path $Cache $asset.name)
    }
    $zip = Join-Path $Cache $assetName
    Test-ArchiveHash $zip (Get-Content -LiteralPath (Join-Path $Cache 'SHA256SUMS.txt') -Raw) $assetName
    & $Progress '校验通过，正在准备安装…'
    $unpacked = Join-Path $Cache ('unpacked-'+[guid]::NewGuid().ToString('N'))
    Expand-CadArchive $zip $unpacked
    $bundle = Join-Path $unpacked 'CadMath03.bundle'
    $info = Get-BundleInfo $bundle
    if ($info.Version -ne $version) { throw '下载版本与包内版本不一致。' }
    return [pscustomobject]@{ Version=$version; Bundle=$bundle }
}

# Registry snapshots preserve value types and unrelated startup entries.
function Open-CadKey([string]$Path) {
    $name=(Get-Item -LiteralPath $Path).Name
    $prefix='HKEY_CURRENT_USER\'
    if (-not $name.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw '只支持当前用户的注册配置。' }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($name.Substring($prefix.Length),$true)
}
function Get-KeySnapshot([string]$Path) {
    $values = @()
    $exists = Test-Path -LiteralPath $Path
    if ($exists) {
        $key = Get-Item -LiteralPath $Path
        foreach ($name in $key.GetValueNames()) { $values += [pscustomobject]@{ Name=$name; Value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind=$key.GetValueKind($name).ToString() } }
    }
    return [pscustomobject]@{ Path=$Path; Exists=$exists; Values=$values }
}
function Restore-KeySnapshot($Snapshot) {
    if (-not $Snapshot.Exists) {
        if (Test-Path -LiteralPath $Snapshot.Path) { Remove-Item -LiteralPath $Snapshot.Path -ErrorAction Stop }
        return
    }
    if (-not (Test-Path -LiteralPath $Snapshot.Path)) { New-Item -Path $Snapshot.Path -Force | Out-Null }
    $key = Open-CadKey $Snapshot.Path
    foreach ($name in $key.GetValueNames()) { $key.DeleteValue($name) }
    foreach ($v in $Snapshot.Values) { $key.SetValue($v.Name,$v.Value,[Microsoft.Win32.RegistryValueKind]$v.Kind) }
}
function Get-RegistrationKeys([string[]]$Products) {
    foreach ($product in $Products) {
        Join-Path $product 'Applications\CadMathInlineMath'
        $profiles = Join-Path $product 'Profiles'
        if (Test-Path -LiteralPath $profiles) {
            foreach ($profile in Get-ChildItem -LiteralPath $profiles) {
                Join-Path $profile.PSPath 'Variables'
                Join-Path $profile.PSPath 'Dialogs\Appload\Startup'
            }
        }
    }
}
function Set-CadRegistration([string[]]$Products,[string]$Target,[bool]$Custom,[scriptblock]$Progress={}) {
    $dll = Join-Path $Target 'Contents\Win64\CadMath03.dll'
    foreach ($product in $Products) {
        $application = Join-Path $product 'Applications\CadMathInlineMath'
        if ($Custom) {
            if (-not (Test-Path -LiteralPath $application)) { New-Item -Path $application -Force | Out-Null }
            $key = Open-CadKey $application
            $key.SetValue('DESCRIPTION','AutoCAD Inline Math')
            $key.SetValue('LOADER',$dll)
            $key.SetValue('LOADCTRLS',2,[Microsoft.Win32.RegistryValueKind]::DWord)
            $key.SetValue('MANAGED',1,[Microsoft.Win32.RegistryValueKind]::DWord)
        } elseif (Test-Path -LiteralPath $application) { Remove-Item -LiteralPath $application }
        $profiles = Join-Path $product 'Profiles'
        if (-not (Test-Path -LiteralPath $profiles)) { continue }
        foreach ($profile in Get-ChildItem -LiteralPath $profiles) {
            $variables = Join-Path $profile.PSPath 'Variables'
            if (-not (Test-Path -LiteralPath $variables)) { New-Item -Path $variables -Force | Out-Null }
            $key = Open-CadKey $variables
            $old = [string]$key.GetValue('TRUSTEDPATHS','')
            $trusted = [IO.Path]::GetDirectoryName($dll)
            if ($old.Split(';') -notcontains $trusted) { $key.SetValue('TRUSTEDPATHS',(($old.Trim(';')+';'+$trusted).Trim(';'))) }
            $startup = Join-Path $profile.PSPath 'Dialogs\Appload\Startup'
            if (-not (Test-Path -LiteralPath $startup)) { continue }
            $sk = Open-CadKey $startup
            $names = @($sk.GetValueNames() | Where-Object { $_ -match '^\d+Startup$' } | Sort-Object { [int]($_ -replace 'Startup','') })
            $keep = @(); $changed = $false
            foreach ($name in $names) {
                $path = [string]$sk.GetValue($name)
                $known = [IO.Path]::GetFileName($path) -in @('CadMath03-Local-Startup.lsp','CadMath03-Startup.lsp')
                # Only migrate helpers issued by this project, never other LSP files.
                if ($known -and (Test-Path -LiteralPath $path)) {
                    $text = Get-Content -LiteralPath $path -Raw
                    if ($text -match 'CadMath03\.dll' -and $text -match 'NETLOAD' -and $text -match 'Local startup helper|Put the extracted CadMath03.bundle') { $changed=$true; continue }
                }
                $keep += $path
            }
            if ($changed) {
                foreach ($name in $names) { $sk.DeleteValue($name) }
                for ($i=0; $i -lt $keep.Count; $i++) { $sk.SetValue(($i+1).ToString()+'Startup',$keep[$i]) }
                $sk.SetValue('NumStartup',[string]$keep.Count)
                & $Progress '已迁移本插件的旧启动组条目，其他 LSP 保持不变。'
            }
        }
    }
}

function Install-CadBundle {
    param([string]$Bundle,[string]$Parent,[string]$StateRoot,[string[]]$Products,
          [string]$DefaultParent,[scriptblock]$Progress={},[scriptblock]$AfterCopy={})
    Assert-CadClosed
    if (-not $Products -or $Products.Count -eq 0) { throw '未找到当前用户的 AutoCAD 2025/2026。请先运行一次 CAD 后重试。' }
    $info = Get-BundleInfo $Bundle
    $target = Get-InstallTarget $Parent
    $defaultTarget = Get-InstallTarget $DefaultParent
    $custom = -not $target.Equals($defaultTarget,[StringComparison]::OrdinalIgnoreCase)
    $stateFile = Join-Path $StateRoot 'install.json'
    if (Test-Path -LiteralPath $stateFile) {
        $previous = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($previous.Target -ne $target) { throw '更新将沿用首次安装目录，请勿更改路径。' }
        if ([version]$info.Version -lt [version]$previous.Version) { throw '下载版本低于当前版本，已阻止降级。' }
    }
    foreach ($existing in @($target,$defaultTarget) | Select-Object -Unique) {
        if (Test-Path -LiteralPath $existing) {
            $oldInfo = Get-BundleInfo $existing
            if ([version]$info.Version -lt [version]$oldInfo.Version) { throw '现有插件版本更高，已阻止降级。' }
        }
    }
    # Snapshot everything before changing the active bundle or registration.
    $transaction = Join-Path $StateRoot ('backups\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $transaction -Force | Out-Null
    $snapshots = @(Get-RegistrationKeys $Products | ForEach-Object { Get-KeySnapshot $_ })
    $snapshots | Export-Clixml -LiteralPath (Join-Path $transaction 'registry.xml')
    $oldState = if (Test-Path -LiteralPath $stateFile) { [IO.File]::ReadAllBytes($stateFile) } else { $null }
    if ($oldState) { [IO.File]::WriteAllBytes((Join-Path $transaction 'install.json'),$oldState) }
    $moves = @(); $placed = $false; $registrationStarted = $false
    $stage = Join-Path ([IO.Path]::GetDirectoryName($target)) ('.CadMath-stage-'+[guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        # Copy only plugin payload. Never execute scripts from downloaded archives.
        Copy-Item -LiteralPath (Join-Path $Bundle 'PackageContents.xml') -Destination $stage
        New-Item -ItemType Directory -Path (Join-Path $stage 'Contents\Win64') -Force | Out-Null
        foreach ($file in @('CadMath03.dll','CadMath03.deps.json')) { Copy-Item -LiteralPath (Join-Path $Bundle "Contents\Win64\$file") -Destination (Join-Path $stage 'Contents\Win64') }
        $null = Get-BundleInfo $stage
        Assert-CadClosed
        foreach ($existing in @($target,$defaultTarget) | Select-Object -Unique) {
            if (Test-Path -LiteralPath $existing) {
                $parentOfExisting = [IO.Path]::GetDirectoryName($existing)
                # Re-check paths immediately before moving; backups stay on the same volume.
                if ((Get-InstallTarget $parentOfExisting) -ne $existing) { throw '安装目标检查失败。' }
                $backup = Join-Path $parentOfExisting ('.CadMath-backup-'+[guid]::NewGuid().ToString('N'))
                Move-Item -LiteralPath $existing -Destination $backup
                $moves += [pscustomobject]@{ Original=$existing; Backup=$backup }
            }
        }
        Move-Item -LiteralPath $stage -Destination $target
        $placed=$true
        & $AfterCopy # fault-injection seam used only by isolated installer tests
        Assert-CadClosed
        $registrationStarted=$true
        Set-CadRegistration $Products $target $custom $Progress
        $result = [pscustomobject]@{ Version=$info.Version; Target=$target; Custom=$custom; Transaction=$transaction; PreviousBundles=$moves }
        $result | Export-Clixml -LiteralPath (Join-Path $transaction 'transaction.xml')
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8
        & $Progress ('安装完成：'+$info.Version+'。请重新打开 CAD。')
        return $result
    } catch {
        $failure = $_
        try {
            if ($registrationStarted) { foreach ($snapshot in $snapshots) { Restore-KeySnapshot $snapshot } }
            if ($placed -and (Test-Path -LiteralPath $target)) {
                $failed = Join-Path ([IO.Path]::GetDirectoryName($target)) ('.CadMath-failed-'+[guid]::NewGuid().ToString('N'))
                if ((Get-InstallTarget ([IO.Path]::GetDirectoryName($target))) -ne $target) { throw '回退目标检查失败。' }
                Move-Item -LiteralPath $target -Destination $failed
            }
            foreach ($move in $moves) { Move-Item -LiteralPath $move.Backup -Destination $move.Original }
            if ($oldState) { [IO.File]::WriteAllBytes($stateFile,$oldState) } elseif (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile }
        } catch { throw "安装失败且回退未完成。请保留备份目录 $transaction。错误：$($_.Exception.Message)；原错误：$($failure.Exception.Message)" }
        throw "安装未完成，原文件和设置已恢复：$($failure.Exception.Message)"
    }
}
