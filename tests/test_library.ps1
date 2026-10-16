$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'Launcher.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
$names=@('Sync-ReplayLibrary','Get-RecordingFileMessage','Save-Paths')
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
if((Get-Content $configFile -Raw | ConvertFrom-Json).autoRecord){throw 'Disabled automatic recording was not saved'}
'PASS: library refresh, selection, file growth/results and automatic recording preference persistence'
