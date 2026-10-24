$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'Launcher.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
$names=@('Sync-ReplayLibrary','Get-RecordingFileMessage','Save-Paths','Import-ReplayFiles','Export-ReplayPackage','Import-ReplayPackage')
foreach($fn in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names},$true)) { . ([ScriptBlock]::Create($fn.Extent.Text)) }
$folder=Join-Path (Split-Path $PSScriptRoot -Parent) ('dist\library-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder | Out-Null
$ui=@{ReplayPath=[pscustomobject]@{Text=$folder};ReplayList=[pscustomobject]@{ItemsSource=@();SelectedItem=$null}}
Sync-ReplayLibrary
if($ui.ReplayList.ItemsSource.Count -ne 0){throw 'Empty library is not empty'}
$first=Join-Path $folder 'Tempest_test_1.replay'
[IO.File]::WriteAllBytes($first,[byte[]](1,2,3))
Sync-ReplayLibrary
if($ui.ReplayList.ItemsSource.Count -ne 1 -or $ui.ReplayList.SelectedItem.Name -ne 'Tempest_test_1.replay'){throw 'New recording did not appear automatically'}
$second=Join-Path $folder 'Tempest_test_2.replay'
[IO.File]::WriteAllBytes($second,[byte[]](4,5,6,7))
(Get-Item $second).LastWriteTime=(Get-Date).AddMinutes(1)
Sync-ReplayLibrary
if($ui.ReplayList.ItemsSource.Count -ne 2 -or $ui.ReplayList.SelectedItem.Name -ne 'Tempest_test_1.replay'){throw 'Selection was not preserved'}
Sync-ReplayLibrary $true
if($ui.ReplayList.SelectedItem.Name -ne 'Tempest_test_2.replay'){throw 'Completed recording was not selected'}
[IO.File]::WriteAllBytes($second,[byte[]](1,2,3,4,5,6))
Sync-ReplayLibrary
if($ui.ReplayList.SelectedItem.Length -ne 6){throw 'Growing recording size was not refreshed'}
$valid=Get-RecordingFileMessage 'Tempest_test_2; driver verified=true' $folder
if($valid -notmatch '6' -or $valid -notlike ('*'+$second+'*')){throw 'Saved file result is missing size/path'}
$missing=Get-RecordingFileMessage 'Tempest_missing; driver verified=true' $folder
if($missing -notmatch '없음'){throw 'Missing file was presented as saved'}
[IO.File]::WriteAllBytes((Join-Path $folder 'Tempest_empty.replay'),[byte[]]@())
if((Get-RecordingFileMessage 'Tempest_empty' $folder) -notmatch '빈 기록'){throw 'Empty recording was presented as saved'}
if((Get-RecordingFileMessage '../invalid' $folder) -notmatch '이름'){throw 'Invalid filename was accepted'}
$configFile=Join-Path $folder 'settings.json'
$settings=@{}
$ui.GamePath=[pscustomobject]@{Text=$folder}
$ui.AutoRecord=[pscustomobject]@{IsChecked=$true}
Save-Paths
if(-not (Get-Content $configFile -Raw | ConvertFrom-Json).autoRecord){throw 'Enabled automatic recording was not saved'}
$ui.AutoRecord.IsChecked=$false
Save-Paths
if(-not (Get-Content $configFile -Raw | ConvertFrom-Json).autoRecord){throw 'Automatic recording must stay enabled regardless of legacy checkbox state'}
'PASS: library refresh, selection, file growth/results and automatic recording preference persistence'

$importSource=Join-Path $folder 'source'
$importTarget=Join-Path $folder 'target'
New-Item -ItemType Directory -Path $importSource,$importTarget | Out-Null
$sourceReplay=Join-Path $importSource 'Companion.replay'
[IO.File]::WriteAllBytes($sourceReplay,[byte[]](1,2,3))
[IO.File]::WriteAllText((Join-Path $importSource 'Companion.movement'),'movement test')
Import-ReplayFiles $sourceReplay $importTarget | Out-Null
if (([IO.File]::ReadAllText((Join-Path $importTarget 'Companion.movement'))) -ne 'movement test') {throw 'Movement companion was not imported'}
$rejected=$false
try {Import-ReplayFiles $sourceReplay $importTarget | Out-Null} catch {$rejected=$true}
if (-not $rejected) {throw 'Existing replay pair was overwritten'}
$legacySource=Join-Path $importSource 'Legacy.replay'
[IO.File]::WriteAllBytes($legacySource,[byte[]](4,5))
Import-ReplayFiles $legacySource $importTarget | Out-Null
if ((Get-Item (Join-Path $importTarget 'Legacy.replay')).Length -ne 2) {throw 'Legacy replay without a companion cannot be imported'}
'PASS: companion import, existing pair protection and legacy import'

# Replay-only launch arguments: run the real session setup against isolated paths.
& {
 $script:BridgeSourceRoot=Split-Path $PSScriptRoot -Parent
 . (Join-Path $script:BridgeSourceRoot 'Bridge.ps1')
 $fake=Join-Path $folder 'bridge-launch'
 $runtime=Join-Path $fake 'runtime'
 $data=Join-Path $fake 'data'
 New-Item -ItemType Directory -Path (Join-Path $runtime 'Mods\TempestReplayBridge\Scripts') -Force | Out-Null
 [IO.File]::WriteAllText((Join-Path $runtime 'tempest-launcher-owned.json'),'{}')
 [IO.File]::WriteAllText((Join-Path $runtime 'Mods\TempestReplayBridge\Scripts\main.lua'),'')
 $steam=Join-Path $fake 'steam.exe';[IO.File]::WriteAllText($steam,'')
 function Get-Process { param($Name,$ErrorAction) return $null }
 function Get-BridgePaths { param($GamePath) return @{Runtime=$runtime;Data=$data} }
 function Get-ItemProperty { param($Path,$ErrorAction) return @{SteamExe=$steam} }
 $script:launches=@()
 function Start-Process { param($FilePath,$ArgumentList,$WindowStyle) $script:launches+=,@{Path=$FilePath;Args=$ArgumentList;Style=$WindowStyle} }
 Start-BridgeSession 'test' record | Out-Null
 if($script:launches[-1].Path -ne 'steam://rungameid/1486920' -or $script:launches[-1].Args){throw 'Live recording launch arguments changed'}
 Start-BridgeSession 'test' play 'TestReplay' | Out-Null
 $last=$script:launches[-1]
 if($last.Path -ne $steam -or ($last.Args -join ' ') -ne '-applaunch 1486920 -NoIntro' -or $last.Style -ne 'Hidden'){throw 'Replay intro launch arguments missing'}
 $request=[IO.File]::ReadAllLines((Join-Path $data 'request.txt'))
 if($request[0] -ne 'play' -or $request[3] -ne 'TestReplay'){throw 'Replay request does not match launch'}
 Start-BridgeSession 'test' record | Out-Null
 if($script:launches[-1].Args){throw 'Replay arguments leaked into next recording'}
 'PASS: replay-only NoIntro, single-use session and unchanged recording launch'
}
& (Join-Path $PSScriptRoot 'test_exit.ps1')
# Single-file sharing round trip, collision preservation and unsafe archive rejection.
$package=Join-Path $folder 'shared.zip'
Export-ReplayPackage $sourceReplay $package | Out-Null
$roundtrip=Join-Path $folder 'roundtrip'
Import-ReplayFiles $package $roundtrip | Out-Null
foreach($extension in @('replay','movement')) {
 if((Get-FileHash (Join-Path $importSource "Companion.$extension")).Hash -ne (Get-FileHash (Join-Path $roundtrip "Companion.$extension")).Hash){throw 'Package roundtrip changed bytes'}
}
$before=(Get-FileHash $package).Hash
$rejected=$false;try{Export-ReplayPackage $sourceReplay $package | Out-Null}catch{$rejected=$true}
if(-not $rejected -or (Get-FileHash $package).Hash -ne $before){throw 'Existing ZIP overwritten'}
$rejected=$false;try{Import-ReplayFiles $package $roundtrip | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Existing pair overwritten by ZIP import'}
foreach($names in @(@('../Escape.replay','Escape.movement'),@('A.replay','B.movement'),@('A.replay','A.replay'),@('A.replay'))) {
 $bad=Join-Path $folder ([guid]::NewGuid().ToString('N')+'.zip')
 $z=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Create)
 try {foreach($name in $names){$e=$z.CreateEntry($name);$s=$e.Open();$s.WriteByte(1);$s.Dispose()}}finally{$z.Dispose()}
 $rejected=$false;try{Import-ReplayFiles $bad (Join-Path $folder 'unsafe') | Out-Null}catch{$rejected=$true}
 if(-not $rejected){throw 'Invalid archive accepted'}
}
'PASS: ZIP pair roundtrip, no overwrite, traversal/mismatched/duplicate/missing entry rejection'
