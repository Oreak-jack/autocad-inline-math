# CadMath 安装工具 · 发布源客户端
# 只有在用户选择「检查更新」时才访问网络。
Set-StrictMode -Version 2

$script:Repository = 'Oreak-jack/autocad-inline-math'
$script:ReleaseApi = 'https://api.github.com/repos/{0}/releases/latest' -f $script:Repository

function Format-TransferSize {
    param([double]$Bytes)
    if ($Bytes -ge 1073741824) { return ('{0:N1} GB' -f ($Bytes / 1073741824)) }
    if ($Bytes -ge 1048576) { return ('{0:N1} MB' -f ($Bytes / 1048576)) }
    if ($Bytes -ge 1024) { return ('{0:N0} KB' -f ($Bytes / 1024)) }
    return ('{0:N0} B' -f $Bytes)
}

function Write-TransferProgress {
    param([long]$Done, [long]$Total, [TimeSpan]$Elapsed)
    $speed = if ($Elapsed.TotalSeconds -gt 0.2) { $Done / $Elapsed.TotalSeconds } else { 0 }
    $speedText = if ($speed -gt 0) { '，{0}/s' -f (Format-TransferSize -Bytes $speed) } else { '' }
    if ($Total -gt 0) {
        $percent = [int](100 * $Done / $Total)
        Write-Host ("`r    已下载 {0} / {1}（{2}%）{3}    " -f (Format-TransferSize -Bytes $Done), (Format-TransferSize -Bytes $Total), $percent, $speedText) -NoNewline
    } else {
        Write-Host ("`r    已下载 {0}{1}    " -f (Format-TransferSize -Bytes $Done), $speedText) -NoNewline
    }
}

function Invoke-ReleaseRequest {
    param([string]$Uri, [int]$TimeoutSec = 20)
    $headers = @{
        'User-Agent' = 'CadMath-Setup'
        'Accept'     = 'application/vnd.github+json'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host ('  请求 {0}' -f $Uri)
    Write-Host ('    （最长等待 {0} 秒，失败会自动重试）' -f $TimeoutSec)
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $result = Invoke-RestMethod -Uri $Uri -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
            $watch.Stop()
            Write-Host ('    → 完成，用时 {0:N1} 秒' -f $watch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
            return $result
        } catch {
            $watch.Stop()
            $lastError = $_.Exception.Message
            Write-Host ('    → 第 {0} 次失败（{1:N1} 秒）：{2}' -f $attempt, $watch.Elapsed.TotalSeconds, $lastError) -ForegroundColor DarkYellow
            if ($attempt -lt 3) {
                Write-Host '      2 秒后重试…'
                Start-Sleep -Seconds 2
            }
        }
    }
    throw ('访问发布源失败：{0}' -f $lastError)
}

function Get-LatestRelease {
    try {
        return (Invoke-ReleaseRequest -Uri $script:ReleaseApi)
    } catch {
        throw ('无法获取最新发行版本：{0}' -f $_.Exception.Message)
    }
}

function Get-ReleaseAssets {
    param([Parameter(Mandatory)]$Release)
    $setupAsset = $null
    $zipAsset = $null
    $sumsAsset = $null
    foreach ($asset in @($Release.assets)) {
        if ($asset.name -like '*setup.json') { $setupAsset = $asset }
        elseif ($asset.name -like '*SHA256SUMS.txt') { $sumsAsset = $asset }
        elseif ($asset.name -like '*.zip') { $zipAsset = $asset }
    }
    if ($setupAsset -eq $null) { throw '这个发行版本没有提供 setup.json，无法校验安装包，已停止。' }
    if ($zipAsset -eq $null) { throw '这个发行版本没有提供安装包 zip。' }
    return [pscustomobject]@{ Setup = $setupAsset; Zip = $zipAsset; Sums = $sumsAsset; Tag = [string]$Release.tag_name; Notes = [string]$Release.body }
}

function Save-RemoteFile {
    param([string]$Uri, [string]$Destination, [int]$TimeoutSec = 600)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            # 自己读流并把进度打出来：Invoke-WebRequest 在整块下载期间一声不响，看起来就像卡死。
            if (-not ('System.Net.Http.HttpClient' -as [type])) {
                Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
            }
            $client = New-Object System.Net.Http.HttpClient
            $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
            $client.DefaultRequestHeaders.Add('User-Agent', 'CadMath-Setup')
            try {
                $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $response.EnsureSuccessStatusCode() | Out-Null
                $total = 0L
                if ($response.Content.Headers.ContentLength) { $total = [long]$response.Content.Headers.ContentLength }
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $file = [System.IO.File]::Create($Destination)
                try {
                    $buffer = New-Object byte[] 81920
                    $done = 0L
                    $watch = [Diagnostics.Stopwatch]::StartNew()
                    $lastTick = [Diagnostics.Stopwatch]::StartNew()
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $file.Write($buffer, 0, $read)
                        $done += $read
                        if ($lastTick.ElapsedMilliseconds -ge 400) {
                            $lastTick.Restart()
                            Write-TransferProgress -Done $done -Total $total -Elapsed $watch.Elapsed
                        }
                    }
                    $watch.Stop()
                    Write-TransferProgress -Done $done -Total $total -Elapsed $watch.Elapsed
                    Write-Host ''
                    Write-Host ('  下载完成：{0}，用时 {1:N1} 秒' -f (Format-TransferSize -Bytes $done), $watch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
                } finally {
                    $file.Close()
                    $stream.Close()
                }
            } finally {
                $client.Dispose()
            }
            return $Destination
        } catch {
            Write-Host ''
            $lastError = $_.Exception.Message
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
            Write-Host ('  第 {0} 次下载失败：{1}' -f $attempt, $lastError) -ForegroundColor DarkYellow
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    }
    throw ('下载失败：{0}' -f $lastError)
}

function Test-NetworkAvailable {
    param([int]$TimeoutMs = 4000)
    try {
        $client = New-Object Net.Sockets.TcpClient
        $task = $client.ConnectAsync('api.github.com', 443)
        if (-not $task.Wait($TimeoutMs)) { $client.Close(); return $false }
        $client.Close()
        return $true
    } catch { return $false }
}

function Compare-ProductVersion {
    param([string]$Current, [string]$Remote)
    if ([string]::IsNullOrWhiteSpace($Current)) { return -1 }
    try { $a = [version]$Current } catch { return -1 }
    try { $b = [version]$Remote } catch { return 1 }
    return $a.CompareTo($b)
}
