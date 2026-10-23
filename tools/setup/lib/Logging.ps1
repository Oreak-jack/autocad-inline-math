# CadMath 安装工具 · 日志
# 每条日志：本地时间戳 + 级别 + 阶段 + 消息；同时写终端与文件。
Set-StrictMode -Version 2

$script:Logger = $null

function New-OperationLogger {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$ToolVersion = '0.0.0'
    )
    $dir = Join-Path $StateRoot 'logs'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ('setup-' + (Get-Date -Format 'yyyyMMdd') + '.log')
    $logger = [pscustomobject]@{
        Path        = $file
        ToolVersion = $ToolVersion
        Quiet       = $false
        Stage       = 'START'
        Warnings    = 0
        Errors      = 0
    }
    $script:Logger = $logger
    return $logger
}

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$Stage,
        [string]$Message
    )
    $logger = $script:Logger
    if ($logger -eq $null) { return }
    if ($PSBoundParameters.ContainsKey('Stage') -and $Stage) { $logger.Stage = $Stage }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] [{2}] {3}' -f $stamp, $Level, $logger.Stage, $Message
    try { Add-Content -LiteralPath $logger.Path -Value $line -Encoding UTF8 } catch { }
    if ($Level -eq 'WARN') { $logger.Warnings++ }
    if ($Level -eq 'ERROR') { $logger.Errors++ }
    if ($logger.Quiet) { return }
    switch ($Level) {
        'INFO'  { Write-Host $line -ForegroundColor Gray }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
    }
}

function Write-Info { param([string]$Stage, [string]$Message) Write-Log -Level INFO -Stage $Stage -Message $Message }
function Write-Warn { param([string]$Stage, [string]$Message) Write-Log -Level WARN -Stage $Stage -Message $Message }
function Write-Err  { param([string]$Stage, [string]$Message) Write-Log -Level ERROR -Stage $Stage -Message $Message }

function Get-LogPath {
    if ($script:Logger -eq $null) { return $null }
    return $script:Logger.Path
}
