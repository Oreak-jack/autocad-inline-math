# CadMath 安装工具 · 发布源客户端
# 只有在用户选择「检查更新」时才访问网络。
Set-StrictMode -Version 2

$script:Repository = 'Oreak-jack/autocad-inline-math'
$script:ReleaseApi = 'https://api.github.com/repos/{0}/releases/latest' -f $script:Repository

function Invoke-ReleaseRequest {
    param([string]$Uri, [int]$TimeoutSec = 20)
    $headers = @{
        'User-Agent' = 'CadMath-Setup'
        'Accept'     = 'application/vnd.github+json'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return (Invoke-RestMethod -Uri $Uri -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop)
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
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
    param([string]$Uri, [string]$Destination, [int]$TimeoutSec = 120)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ 'User-Agent' = 'CadMath-Setup' } -ErrorAction Stop
            return $Destination
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
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
