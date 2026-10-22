param([Parameter(Mandatory=$true)][string]$Bundle,[Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Install-Core.ps1')
$count=0
function Check([bool]$Pass,[string]$Message) { if (-not $Pass) { throw "FAIL: $Message" }; $script:count++ }
function Fails([scriptblock]$Action,[string]$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
$testId=[guid]::NewGuid().ToString('N')
$root=Join-Path ([IO.Path]::GetFullPath($TestRoot)) $testId
New-Item -ItemType Directory -Path $root -Force | Out-Null
$regRoot='HKCU:\Software\CadMathInstallerTests\'+$testId
$product=Join-Path $regRoot 'R25.1\ACAD-9101:804'
$variables=Join-Path $product 'Profiles\Test\Variables'
$startup=Join-Path $product 'Profiles\Test\Dialogs\Appload\Startup'
New-Item -Path $variables,$startup -Force | Out-Null
try {
    function Get-Process { [pscustomobject]@{ProcessName='acad'} }
    Fails { Assert-CadClosed } 'running CAD prevents installation'
    Remove-Item Function:\Get-Process
    # Tests affect only temporary files and the dedicated HKCU test subtree.
    function Assert-CadClosed { }
    $info=Get-BundleInfo $Bundle
    Check ($info.Version -eq '0.3.2') 'payload version'
    Check (@(Get-CadProducts $regRoot).Count -eq 1) 'AutoCAD discovery in isolated registry'
    Fails { Get-InstallTarget '\\server\share' } 'reject network target'
    Fails { Get-InstallTarget 'relative' } 'reject relative target'
    Fails { Get-InstallTarget 'C:\bad;path' } 'reject trusted-path delimiter'
    Check ((Get-InstallTarget 'C:\') -eq 'C:\CadMath03.bundle') 'drive root resolved correctly'
    $hidden=Join-Path $root 'hidden-parent'
    $null=New-Item -ItemType Directory -Path $hidden
    [IO.File]::SetAttributes($hidden,([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System))
    Check ((Get-InstallTarget (Join-Path $hidden 'plugins')) -eq (Join-Path $hidden 'plugins\CadMath03.bundle')) 'hidden/system ancestor accepted'
    $actualDefault=Join-Path $env:APPDATA 'Autodesk\ApplicationPlugins'
    Check ((Get-InstallTarget $actualDefault) -eq (Join-Path $actualDefault 'CadMath03.bundle')) 'real AppData default checked without writes'
    $vk=Open-CadKey $variables
    $vk.SetValue('TRUSTEDPATHS','D:\OtherPlugin')
    $vk.SetValue('SECURELOAD',2,[Microsoft.Win32.RegistryValueKind]::DWord)
    $vk.SetValue('Unrelated','keep-me')
    $helper=Join-Path $root 'CadMath03-Local-Startup.lsp'
    Set-Content -LiteralPath $helper -Value ';; Local startup helper. (command "_.NETLOAD" "C:/old/CadMath03.dll")' -Encoding ASCII
    $sk=Open-CadKey $startup
    $sk.SetValue('1Startup','C:\Other\tool.lsp'); $sk.SetValue('2Startup',$helper); $sk.SetValue('NumStartup','2')
    $default=Join-Path $root 'default'
    $state=Join-Path $root 'state'
    $result=Install-CadBundle -Bundle $Bundle -Parent $default -StateRoot $state -Products @($product) -DefaultParent $default
    Check ((Get-BundleInfo $result.Target).Version -eq '0.3.2') 'first default install'
    Check (-not $result.Custom) 'default uses bundle auto-loading'
    Check ((Open-CadKey $variables).GetValue('SECURELOAD') -eq 2) 'security setting preserved'
    Check ((Open-CadKey $variables).GetValue('Unrelated') -eq 'keep-me') 'other profile values preserved'
    Check ((Open-CadKey $variables).GetValue('TRUSTEDPATHS').StartsWith('D:\OtherPlugin;')) 'trusted path appended'
    Check ((Open-CadKey $startup).GetValue('1Startup') -eq 'C:\Other\tool.lsp') 'other startup plugin preserved'
    Check ((Open-CadKey $startup).GetValue('NumStartup') -eq '1') 'old helper migrated'
    Check (Test-Path -LiteralPath $helper) 'old helper file preserved'
    $firstHash=(Get-FileHash -LiteralPath (Join-Path $result.Target 'Contents\Win64\CadMath03.dll')).Hash
    $again=Install-CadBundle -Bundle $Bundle -Parent $default -StateRoot $state -Products @($product) -DefaultParent $default
    Check ($again.PreviousBundles.Count -eq 1) 'update keeps backup'
    Check ((Get-FileHash -LiteralPath (Join-Path $again.Target 'Contents\Win64\CadMath03.dll')).Hash -eq $firstHash) 'updated DLL intact'
    Fails { Install-CadBundle -Bundle $Bundle -Parent $default -StateRoot $state -Products @($product) -DefaultParent $default -AfterCopy { throw 'simulated disk failure' } } 'interrupted update fails'
    Check ((Get-FileHash -LiteralPath (Join-Path $again.Target 'Contents\Win64\CadMath03.dll')).Hash -eq $firstHash) 'DLL restored after failure'
    Check ((Get-Content -LiteralPath (Join-Path $state 'install.json') -Raw | ConvertFrom-Json).Target -eq $again.Target) 'saved location restored'
    Fails { Install-CadBundle -Bundle $Bundle -Parent (Join-Path $root 'moved') -StateRoot $state -Products @($product) -DefaultParent $default } 'updates keep chosen location'
    $custom=Join-Path $root 'custom'
    $customState=Join-Path $root 'custom-state'
    $customResult=Install-CadBundle -Bundle $Bundle -Parent $custom -StateRoot $customState -Products @($product) -DefaultParent $default
    Check $customResult.Custom 'custom installation'
    Check (-not (Test-Path -LiteralPath (Join-Path $default 'CadMath03.bundle'))) 'old default migrated to backup'
    $app=Open-CadKey (Join-Path $product 'Applications\CadMathInlineMath')
    Check ($app.GetValue('LOADCTRLS') -eq 2 -and $app.GetValue('MANAGED') -eq 1) 'custom startup registration'
    Check ($app.GetValue('LOADER') -eq (Join-Path $customResult.Target 'Contents\Win64\CadMath03.dll')) 'custom path used by AutoCAD'
    # Inject failure after registration, then verify profile and files roll back.
    $originalRegistration=${function:Set-CadRegistration}
    function Set-CadRegistration { param($Products,$Target,$Custom,$Progress)
        & $originalRegistration $Products $Target $Custom $Progress
        (Open-CadKey $variables).SetValue('Unrelated','damaged')
        throw 'simulated registration failure'
    }
    Fails { Install-CadBundle -Bundle $Bundle -Parent $custom -StateRoot $customState -Products @($product) -DefaultParent $default } 'registration failure rolls back'
    Check ((Open-CadKey $variables).GetValue('Unrelated') -eq 'keep-me') 'registry values restored'
    Check ((Open-CadKey $variables).GetValueKind('SECURELOAD') -eq 'DWord') 'registry types restored'
    Set-Item Function:\Set-CadRegistration $originalRegistration
    $unknown=Join-Path $root 'unknown\CadMath03.bundle'
    New-Item -ItemType Directory -Path $unknown -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $unknown 'keep.txt') 'unrelated'
    Fails { Install-CadBundle -Bundle $Bundle -Parent ([IO.Path]::GetDirectoryName($unknown)) -StateRoot (Join-Path $root 'unknown-state') -Products @($product) -DefaultParent $default } 'unknown directory not overwritten'
    Check (Test-Path -LiteralPath (Join-Path $unknown 'keep.txt')) 'unknown content intact'
    Fails { Install-CadBundle -Bundle $Bundle -Parent $default -StateRoot $state -Products @() -DefaultParent $default } 'missing AutoCAD rejected'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $validZip=Join-Path $root 'valid.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($Bundle,$validZip)
    $hash=(Get-FileHash -LiteralPath $validZip).Hash
    Test-ArchiveHash $validZip "$hash  valid.zip" 'valid.zip'; Check $true 'valid checksum accepted'
    Fails { Test-ArchiveHash $validZip (('0'*64)+'  valid.zip') 'valid.zip' } 'bad checksum rejected'
    $badZip=Join-Path $root 'traversal.zip'
    $zip=[IO.Compression.ZipFile]::Open($badZip,[IO.Compression.ZipArchiveMode]::Create)
    $null=$zip.CreateEntry('../outside.txt'); $zip.Dispose()
    Fails { Expand-CadArchive $badZip (Join-Path $root 'unpacked') } 'zip traversal rejected'
    Check (-not (Test-Path -LiteralPath (Join-Path $root 'outside.txt'))) 'no zip escape'
    # Simulate a stale online release by marking the installed version newer.
    $saved=Get-Content -LiteralPath (Join-Path $customState 'install.json') -Raw | ConvertFrom-Json
    $saved.Version='9.0.0'; $saved | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $customState 'install.json')
    Fails { Install-CadBundle -Bundle $Bundle -Parent $custom -StateRoot $customState -Products @($product) -DefaultParent $default } 'downgrade rejected'
    Write-Output "PASS $count installer checks. Isolated filesystem/registry only; native AutoCAD load not tested."
} finally {
    # Verify the exact dedicated registry test subtree before recursive cleanup.
    if ($regRoot -eq ('HKCU:\Software\CadMathInstallerTests\'+$testId) -and $testId -match '^[0-9a-f]{32}$') { Remove-Item -LiteralPath $regRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Output "Test files retained: $root"
}
