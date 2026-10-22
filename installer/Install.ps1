param([switch]$SmokeTest,[string]$UiTestScript)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Install-Core.ps1')
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$stateRoot = Join-Path $env:LOCALAPPDATA 'CadMathInlineMath'
$defaultParent = Join-Path $env:APPDATA 'Autodesk\ApplicationPlugins'
$script:pending = $null; $script:downloadJob = $null; $script:busy = $false
$managerSource = $PSScriptRoot
$script:managerReady = $false
$script:bundledPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\CadMath03.bundle'))
function Show-Notice([string]$Text,[string]$Title='CAD 四则运算',[string]$Icon='Information') {
    [Windows.Forms.MessageBox]::Show($Text,$Title,'OK',$Icon) | Out-Null
}
$mutexName=if($SmokeTest -or $UiTestScript){'Local\CadMathInstallerTest-'+[guid]::NewGuid().ToString('N')}else{'Local\CadMathInlineMathInstaller'}
$mutex = New-Object Threading.Mutex($false,$mutexName)
if (-not $mutex.WaitOne(0)) {
    [Windows.Forms.MessageBox]::Show('另一个安装或更新窗口已经打开。','CAD 四则运算') | Out-Null
    exit 1
}
function Save-Manager {
    $manager = Join-Path $stateRoot 'Manager'
    New-Item -ItemType Directory -Path $manager -Force | Out-Null
    foreach ($name in @('Install.ps1','Install-Core.ps1','Install.cmd')) {
        $source = Join-Path $managerSource $name
        $dest = Join-Path $manager $name
        if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($dest)) { Copy-Item -LiteralPath $source -Destination $dest -Force }
    }
    $shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CAD 四则运算 - 检查更新.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "'+(Join-Path $manager 'Install.ps1')+'"'
    $link.WorkingDirectory = $manager
    $link.Description = '下载并安装 CAD 四则运算最新正式版'
    $link.Save()
    $script:managerReady = $true
}
$form = New-Object Windows.Forms.Form
$form.Text = 'CAD 四则运算 · 安装与更新'
$form.ClientSize = New-Object Drawing.Size(630,450)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox=$false
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI',10)
$title = New-Object Windows.Forms.Label
$title.Text = '一次安装，以后点击桌面的“检查更新”'
$title.Location = New-Object Drawing.Point(22,20); $title.Size = New-Object Drawing.Size(585,32)
$title.Font = New-Object Drawing.Font('Microsoft YaHei UI',13,[Drawing.FontStyle]::Bold)
$form.Controls.Add($title)
$locationLabel = New-Object Windows.Forms.Label
$locationLabel.Text='安装目录（首次可选，更新沿用此位置）：'
$locationLabel.Location=New-Object Drawing.Point(22,65); $locationLabel.Size=New-Object Drawing.Size(570,25)
$form.Controls.Add($locationLabel)
$pathBox=New-Object Windows.Forms.TextBox
$pathBox.Location=New-Object Drawing.Point(22,95); $pathBox.Size=New-Object Drawing.Size(485,28)
$pathBox.Text=$defaultParent
$form.Controls.Add($pathBox)
$browse=New-Object Windows.Forms.Button
$browse.Text='浏览…'; $browse.Location=New-Object Drawing.Point(520,93); $browse.Size=New-Object Drawing.Size(87,31)
$form.Controls.Add($browse)
$detail=New-Object Windows.Forms.Label
$detail.Text='支持 Windows AutoCAD 2025 / 2026。安装时自动配置加载位置，迁移本插件旧启动组条目，并添加插件文件夹到可信路径。首次可能仍需确认未签名插件提示。'
$detail.Location=New-Object Drawing.Point(22,140); $detail.Size=New-Object Drawing.Size(580,65)
$form.Controls.Add($detail)
$status=New-Object Windows.Forms.Label
$status.Text='准备就绪。点击按钮查询并自动下载最新正式版。'
$status.Location=New-Object Drawing.Point(22,220); $status.Size=New-Object Drawing.Size(580,75)
$form.Controls.Add($status)
$install=New-Object Windows.Forms.Button
$install.Text='下载并安装 / 更新'; $install.Location=New-Object Drawing.Point(22,320); $install.Size=New-Object Drawing.Size(260,45)
$form.Controls.Add($install)
$offline=New-Object Windows.Forms.Button
$offline.Text='使用随包版本（离线）'; $offline.Location=New-Object Drawing.Point(300,320); $offline.Size=New-Object Drawing.Size(215,45)
$offline.Visible=Test-Path -LiteralPath (Join-Path $script:bundledPath 'PackageContents.xml')
$form.Controls.Add($offline)
$done=New-Object Windows.Forms.Button
$done.Text='关闭'; $done.Location=New-Object Drawing.Point(520,320); $done.Size=New-Object Drawing.Size(87,45)
$form.Controls.Add($done)
$done.Add_Click({ $form.Close() })
$repair=New-Object Windows.Forms.CheckBox
$repair.Text='重新安装相同版本（修复加载配置）'; $repair.Location=New-Object Drawing.Point(22,375); $repair.Size=New-Object Drawing.Size(570,25)
$form.Controls.Add($repair)
$tip=New-Object Windows.Forms.Label
$tip.Text='下载 → 校验 → 保存图纸并关闭 CAD → 自动安装 → 重新打开 CAD'
$tip.Location=New-Object Drawing.Point(22,415); $tip.Size=New-Object Drawing.Size(585,24)
$form.Controls.Add($tip)
$stateFile=Join-Path $stateRoot 'install.json'
if (Test-Path -LiteralPath $stateFile) {
    try {
        $saved=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $pathBox.Text=[IO.Path]::GetDirectoryName($saved.Target)
        $pathBox.ReadOnly=$true; $browse.Enabled=$false
        $status.Text='已安装 '+$saved.Version+'。点击按钮检查并下载更新。'
    } catch { $status.Text='安装记录无法读取；请保留现有文件并查看安装说明。'; $install.Enabled=$false; $offline.Enabled=$false }
}
$browse.Add_Click({
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description='选择安装目录，安装器会在其中创建 CadMath03.bundle'
    if ($dialog.ShowDialog() -eq 'OK') { $pathBox.Text=$dialog.SelectedPath }
    $dialog.Dispose()
})
function Complete-Install {
    $script:busy=$true; $install.Enabled=$false; $offline.Enabled=$false; $browse.Enabled=$false; $done.Enabled=$false
    try {
        $target=Get-InstallTarget $pathBox.Text
        if ((Test-Path -LiteralPath $stateFile) -and (Test-Path -LiteralPath $target)) {
            $existing=Get-BundleInfo $target
            if ([version]$existing.Version -gt [version]$script:pending.Version) { throw ('所选版本 '+$script:pending.Version+' 低于已安装版本 '+$existing.Version+'，不会降级。') }
            if (-not $repair.Checked -and $existing.Version -eq $script:pending.Version) {
                $incoming=Join-Path $script:pending.Bundle 'Contents\Win64\CadMath03.dll'
                if ((Get-FileHash -LiteralPath $existing.Dll).Hash -eq (Get-FileHash -LiteralPath $incoming).Hash) {
                    $label=if($script:pending.Origin -eq 'offline'){'随包版本'}else{'最新正式版'}
                    $message='当前已安装 '+$existing.Version+'，与'+$label+'相同，无需重复安装。如需修复自动加载，请勾选“重新安装相同版本”后再点安装。'
                    $status.Text=$message; $script:pending=$null; $install.Text='检查更新'; $done.Text='完成并关闭'
                    Show-Notice $message
                    return
                }
            }
        }
        if (Get-Process -Name acad,accoreconsole -ErrorAction SilentlyContinue) {
            $ready=if($script:pending.Origin -eq 'offline'){'随包版本已就绪，无需联网。'}else{'已下载并校验。'}
            $status.Text=$ready+'请保存图纸，关闭所有 CAD 窗口，然后点“CAD 已关闭，继续安装”。'
            $install.Text='CAD 已关闭，继续安装'
            return
        }
        $products=@(Get-CadProducts)
        # Make the updater available first; a shortcut failure must not strand an installed plugin.
        if (-not $script:managerReady) { Save-Manager }
        $result=Install-CadBundle -Bundle $script:pending.Bundle -Parent $pathBox.Text -StateRoot $stateRoot -Products $products -DefaultParent $defaultParent -Progress { param($text) $status.Text=$text; $status.Refresh() }
        $pathBox.ReadOnly=$true
        $status.Text='已安装 '+$result.Version+'。重新打开 CAD 即可使用；输入 CM3STATUS 可检查版本。以后双击桌面“CAD 四则运算 - 检查更新”。'
        $install.Text='检查更新'; $script:pending=$null; $done.Text='完成并关闭'; $repair.Checked=$false
        Show-Notice $status.Text '安装完成'
    } catch {
        $status.Text=$_.Exception.Message
        Show-Notice $_.Exception.Message '安装未完成' 'Warning'
    } finally {
        $script:busy=$false; $install.Enabled=$true; $offline.Enabled=$true; $done.Enabled=$true
        $browse.Enabled=-not $pathBox.ReadOnly
    }
}
$timer=New-Object Windows.Forms.Timer
$timer.Interval=250
function Poll-Download {
    if ($null -eq $script:downloadJob) { return }
    $messages=@($script:downloadJob.ChildJobs[0].Information)
    if ($messages.Count -gt 0) { $status.Text=[string]$messages[-1].MessageData }
    foreach ($item in @(Receive-Job -Job $script:downloadJob -InformationAction SilentlyContinue 6>$null)) {
        if ($item.Kind -eq 'progress') { $status.Text=$item.Text }
        elseif ($item.Kind -eq 'ready') { $script:pending=$item.Release }
        elseif ($item.Kind -eq 'error') { $status.Text='下载未完成，现有插件没有改变：'+$item.Text }
    }
    if ($script:downloadJob.State -in @('Completed','Failed','Stopped')) {
        # Drain results that arrived after the first Receive-Job.
        foreach ($item in @(Receive-Job -Job $script:downloadJob -InformationAction SilentlyContinue 6>$null)) {
            if ($item.Kind -eq 'ready') { $script:pending=$item.Release }
            elseif ($item.Kind -eq 'error') { $status.Text='下载未完成，现有插件没有改变：'+$item.Text }
        }
        Remove-Job -Job $script:downloadJob; $script:downloadJob=$null
        $script:busy=$false; $install.Enabled=$true; $offline.Enabled=$true
        $browse.Enabled=-not $pathBox.ReadOnly
        if ($script:pending) { Complete-Install }
    }
}
$timer.Add_Tick({
    try { Poll-Download } catch {
        $status.Text='更新未完成：'+$_.Exception.Message
        if ($script:downloadJob) { Stop-Job $script:downloadJob; Remove-Job $script:downloadJob; $script:downloadJob=$null }
        $script:busy=$false; $install.Enabled=$true; $offline.Enabled=$true; $browse.Enabled=-not $pathBox.ReadOnly
    }
})
$install.Add_Click({
    if ($script:pending) { Complete-Install; return }
    try {
        $null=Get-InstallTarget $pathBox.Text
        if (@(Get-CadProducts).Count -eq 0) { throw '请先在当前 Windows 用户下运行一次 AutoCAD 2025/2026，再安装插件。' }
        $script:busy=$true; $install.Enabled=$false; $offline.Enabled=$false; $browse.Enabled=$false
        $status.Text='正在查询新版本…'
        $cache=Join-Path $stateRoot ('downloads\'+[guid]::NewGuid().ToString('N'))
        $script:downloadJob=Start-Job -ArgumentList (Join-Path $managerSource 'Install-Core.ps1'),$cache -ScriptBlock {
            param($core,$cache)
            try {
                . $core
                $release=Get-CadRelease $cache { param($text) Write-Information $text -InformationAction Continue }
                $release | Add-Member -NotePropertyName Origin -NotePropertyValue online
                [pscustomobject]@{Kind='ready';Release=$release}
            } catch { [pscustomobject]@{Kind='error';Text=$_.Exception.Message} }
        }
    } catch { $status.Text=$_.Exception.Message; $script:busy=$false; $install.Enabled=$true; $offline.Enabled=$true; $browse.Enabled=-not $pathBox.ReadOnly }
})
$offline.Add_Click({
    try {
        $bundle=$script:bundledPath
        $info=Get-BundleInfo $bundle
        $script:pending=[pscustomobject]@{Bundle=$bundle;Version=$info.Version;Origin='offline'}
        Complete-Install
    } catch { $status.Text=$_.Exception.Message; Show-Notice $_.Exception.Message '随包安装未完成' 'Warning' }
})
$form.Add_FormClosing({ param($sender,$eventArgs)
    if ($script:busy -and $null -eq $script:downloadJob) { $eventArgs.Cancel=$true }
})
try {
    if ($UiTestScript) { . $UiTestScript }
    elseif ($SmokeTest) { $form.CreateControl(); Write-Output 'PASS installer form construction; no settings changed.' }
    else { $timer.Start(); [void]$form.ShowDialog() }
} finally {
    $timer.Stop(); $timer.Dispose()
    if ($script:downloadJob) { Stop-Job $script:downloadJob; Remove-Job $script:downloadJob }
    $form.Dispose(); $mutex.ReleaseMutex(); $mutex.Dispose()
}
