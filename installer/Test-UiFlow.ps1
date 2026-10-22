# Dot-sourced only by Install.ps1 -UiTestScript. Uses actual event handlers,
# local payload files and mocked installation, notices and CAD process state.
$script:uiCount=0; $script:installCalls=0; $script:cadRunning=$false; $script:simulateFailure=$false
$script:notices=@()
function UiCheck([bool]$ok,[string]$message){if(-not $ok){throw "UI FAIL: $message ($($status.Text))"};$script:uiCount++}
function Click-TestButton($button){
    $method=$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
    $null=$method.Invoke($button,@([EventArgs]::Empty))
}
function Show-Notice([string]$Text,[string]$Title,[string]$Icon){$script:notices+=@($Text)}
function Save-Manager {$script:managerReady=$true}
function Get-CadProducts { 'test-product' }
function Get-Process { if($script:cadRunning){[pscustomobject]@{ProcessName='acad'}} }
function Install-CadBundle {
    param($Bundle,$Parent,$StateRoot,$Products,$DefaultParent,$Progress)
    $script:installCalls++
    if($script:simulateFailure){throw 'simulated installation failure'}
    [pscustomobject]@{Version=(Get-BundleInfo $Bundle).Version}
}
$script:bundledPath=$env:CADMATH_UI_TEST_BUNDLE
if(-not $script:bundledPath){throw 'CADMATH_UI_TEST_BUNDLE is required'}
$testRoot=Join-Path $env:TEMP ('CadMathUiTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$stateRoot=Join-Path $testRoot 'state';$stateFile=Join-Path $stateRoot 'install.json'
$pathBox.Text=Join-Path $testRoot 'plugins'; $pathBox.ReadOnly=$false
$offline.Visible=$true
Click-TestButton $offline
UiCheck ($script:installCalls -eq 1) 'offline invokes installer without a download job'
UiCheck ($null -eq $script:downloadJob -and $null -eq $script:pending) 'offline has no network job and clears pending'
UiCheck ($done.Text -eq '完成并关闭' -and $script:notices.Count -eq 1) 'completion is visible'
$script:cadRunning=$true
Click-TestButton $offline
UiCheck ($script:installCalls -eq 1 -and $script:pending.Origin -eq 'offline') 'wait for CAD without installing'
UiCheck ($status.Text.Contains('无需联网') -and $install.Text.Contains('继续安装')) 'offline waiting text is accurate'
$script:cadRunning=$false
Click-TestButton $install
UiCheck ($script:installCalls -eq 2 -and $null -eq $script:downloadJob) 'continue uses offline payload, not download'
New-Item -ItemType Directory -Path $pathBox.Text,$stateRoot -Force | Out-Null
Copy-Item -LiteralPath $script:bundledPath -Destination $pathBox.Text -Recurse
Set-Content -LiteralPath $stateFile '{}'
Click-TestButton $offline
UiCheck ($script:installCalls -eq 2 -and $status.Text.Contains('无需重复安装')) 'same version does not silently reinstall'
$repair.Checked=$true
Click-TestButton $offline
UiCheck ($script:installCalls -eq 3 -and -not $repair.Checked) 'explicit repair reinstalls same version'
$repair.Checked=$true;$script:simulateFailure=$true
Click-TestButton $offline
UiCheck ($status.Text.Contains('simulated installation failure') -and $done.Enabled -and $offline.Enabled) 'failure visible and buttons recover'
$script:simulateFailure=$false;$repair.Checked=$false;$script:pending=$null
$script:downloadJob=Start-Job {Write-Information 'preparing' -InformationAction Continue;[pscustomobject]@{Kind='error';Text='network test error'}}
$null=Wait-Job $script:downloadJob -Timeout 15
Poll-Download
UiCheck ($null -eq $script:downloadJob -and $status.Text.Contains('network test error') -and $install.Enabled) 'download error does not leave preparing status'
$script:downloadJob=Start-Job -ArgumentList $script:bundledPath -ScriptBlock {param($bundle);[pscustomobject]@{Kind='ready';Release=[pscustomobject]@{Bundle=$bundle;Version='0.3.3';Origin='online'}}}
$null=Wait-Job $script:downloadJob -Timeout 15
Poll-Download
UiCheck ($script:installCalls -eq 4 -and $status.Text.Contains('最新正式版') -and $null -eq $script:downloadJob) 'online ready same-version result stops at final status'
Click-TestButton $done
UiCheck ($form.IsDisposed) 'Done closes the actual form'
Write-Output "PASS $script:uiCount UI event-flow checks; no real CAD settings changed."
