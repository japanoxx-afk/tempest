$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Update.ps1') -LibraryOnly
$testRoot=Join-Path (Split-Path $PSScriptRoot -Parent) ('dist\update-test-'+[guid]::NewGuid().ToString('N'))
$package=Join-Path $testRoot 'package';$target=Join-Path $testRoot 'target';$backup=Join-Path $testRoot 'backup'
foreach($name in @('Launcher.ps1','Start.cmd','version.json','Update.ps1','Bridge.ps1','ReplayBridge\Scripts\main.lua','ReplayBridge\Scripts\Movement.lua','ReplayBridge\WatchExit.ps1')) {
 $path=Join-Path $package $name;New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
 [IO.File]::WriteAllText($path,'new-'+$name)
}
[IO.File]::WriteAllText((Join-Path $package 'version.json'),'{"version":"9.0.0"}')
New-Item -ItemType Directory -Path (Join-Path $target 'ReplayBridge\Scripts') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $target 'ReplayBridge\Scripts\main.lua'),'old-main')
[IO.File]::WriteAllText((Join-Path $target 'user-setting.txt'),'preserve')
Install-LauncherUpdate $package $target $backup
if([IO.File]::ReadAllText((Join-Path $target 'ReplayBridge\Scripts\main.lua')) -ne 'new-ReplayBridge\Scripts\main.lua'){throw 'Nested bridge replacement failed'}
if(Test-Path (Join-Path $target 'ReplayBridge\ReplayBridge')){throw 'Nested duplicate bridge folder created'}
if([IO.File]::ReadAllText((Join-Path $backup 'ReplayBridge\Scripts\main.lua')) -ne 'old-main'){throw 'Backup lost'}
if([IO.File]::ReadAllText((Join-Path $target 'user-setting.txt')) -ne 'preserve'){throw 'Unrelated file changed'}
'PASS: update installation replaces nested files, keeps backup and preserves unrelated files'
$StatusPath=Join-Path $testRoot 'status.json'
Write-UpdateState 'checking' 'Checking'
if((Get-Content $StatusPath -Raw | ConvertFrom-Json).state -ne 'checking'){throw 'Progress missing'}
Write-UpdateState 'verifying' '다운로드 검증 및 압축 해제 중…'
$bytes=[IO.File]::ReadAllBytes($StatusPath)
if($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191){throw 'Status must include a UTF8 BOM for legacy PS 5.1 readers'}
$legacy=Get-Content $StatusPath -Raw | ConvertFrom-Json
if($legacy.message -cne '다운로드 검증 및 압축 해제 중…' -or $legacy.state -ne 'verifying'){throw 'Legacy reader corrupts Korean progress'}
'PASS: Korean status JSON is readable by legacy Windows PowerShell 5.1'
$archive=Join-Path $testRoot 'fixture.zip'
Compress-Archive -Path (Join-Path $package '*') -DestinationPath $archive
$script:fixtureZip=$archive
$fixtureHash=(Get-FileHash $archive).Hash
function Invoke-RestMethod {return [pscustomobject]@{tag_name='v9.0.0';assets=@([pscustomobject]@{name='TempestReplayLauncher.zip';browser_download_url='fixture:zip'},[pscustomobject]@{name='TempestReplayLauncher.zip.sha256';browser_download_url='fixture:hash'})}}
function Invoke-WebRequest {param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec)
 if($Uri -eq 'fixture:zip'){Copy-Item $script:fixtureZip $OutFile}
 else{[IO.File]::WriteAllBytes($OutFile,[Text.Encoding]::UTF8.GetBytes($fixtureHash+"`r`n"))}
}
$received=Receive-LauncherUpdate (Join-Path $testRoot 'download') '1.0.0'
if(-not (Test-Path (Join-Path $received 'ReplayBridge\Scripts\Movement.lua'))){throw 'Download package missing'}
if($null -ne (Receive-LauncherUpdate (Join-Path $testRoot 'current') '9.0.0')){throw 'Current release installed again'}
'PASS: binary checksum response, package verification and current-version detection'
$fixtureHash='0'*64
$rejected=$false
try{Receive-LauncherUpdate (Join-Path $testRoot 'bad-hash') '1.0.0' | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Bad checksum accepted'}
'PASS: checksum mismatch rejected before installation'
[IO.File]::WriteAllText((Join-Path $target 'Launcher.ps1'),'previous-launcher')
Remove-Item -LiteralPath (Join-Path $target 'Update.ps1')
$script:failedSource=Join-Path $package 'Bridge.ps1';$script:failedOnce=$false
function Copy-Item {param($LiteralPath,$Destination,[switch]$Force)
 if($LiteralPath -eq $script:failedSource -and -not $script:failedOnce){$script:failedOnce=$true;throw 'Simulated write failure'}
 Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}
$failed=$false
try{Install-LauncherUpdate $package $target (Join-Path $testRoot 'rollback-backup')}catch{$failed=$true}
if(-not $failed -or [IO.File]::ReadAllText((Join-Path $target 'Launcher.ps1')) -ne 'previous-launcher'){throw 'Failed update did not restore old launcher'}
if(Test-Path -LiteralPath (Join-Path $target 'Update.ps1')){throw 'Failed update retained a newly copied file'}
'PASS: partial installation failure rolls back replaced and newly created files'
$launcherPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'Launcher.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($launcherPath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
$click=$ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$ui.Update' -and $n.Member.Value -eq 'Add_Click'},$true) | Select-Object -First 1
$tick=$ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$updateTimer' -and $n.Member.Value -eq 'Add_Tick'},$true) | Select-Object -First 1
$ui=@{Update=[pscustomobject]@{IsEnabled=$true;Content='Update'};Status=[pscustomobject]@{Text=''}}
function Get-LocalizedText([string]$Text){return $Text}
$data=$testRoot;$root=$target;$version='1.0.0'
$window=[pscustomobject]@{Closed=$false};$window | Add-Member ScriptMethod Close {$this.Closed=$true}
$updateTimer=[pscustomobject]@{Running=$false};$updateTimer | Add-Member ScriptMethod Start {$this.Running=$true};$updateTimer | Add-Member ScriptMethod Stop {$this.Running=$false}
function Start-Process {param($FilePath,$WindowStyle,[switch]$PassThru,$ArgumentList)
 if($FilePath -ne 'powershell.exe' -or $WindowStyle -ne 'Hidden' -or '-Check' -notin $ArgumentList -or -not $PassThru){throw 'Updater worker not dispatched in background'}
 return [pscustomobject]@{HasExited=$false}
}
& $click.Arguments[0].ScriptBlock.GetScriptBlock()
if($ui.Update.IsEnabled -or -not $updateTimer.Running){throw 'Update click did not return with polling active'}
$StatusPath=$script:updateStatusFile
Write-UpdateState 'verifying' '다운로드 검증 및 압축 해제 중…'
& $tick.Arguments[0].ScriptBlock.GetScriptBlock()
if($window.Closed -or $ui.Status.Text -cne '다운로드 검증 및 압축 해제 중…'){throw 'Launcher closed or corrupted Korean verification progress'}
# Read statuses emitted by already installed workers with BOM-less UTF8 too.
$oldStatus='{"message":"다운로드 검증 및 압축 해제 중…","state":"verifying"}'
[IO.File]::WriteAllText($StatusPath,$oldStatus,(New-Object Text.UTF8Encoding($false)))
& $tick.Arguments[0].ScriptBlock.GetScriptBlock()
if($window.Closed -or $ui.Status.Text -cne '다운로드 검증 및 압축 해제 중…'){throw 'BOM-less legacy worker status corrupted'}
Write-UpdateState 'ready' 'Ready'
& $tick.Arguments[0].ScriptBlock.GetScriptBlock()
if(-not $window.Closed -or $updateTimer.Running){throw 'Verified updater did not close launcher for replacement'}
'PASS: update button dispatches a worker, reports progress and closes only when verified'
