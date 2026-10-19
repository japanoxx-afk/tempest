$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$root=Split-Path $PSScriptRoot -Parent
$source=[IO.File]::ReadAllText((Join-Path $root 'Launcher.ps1'))
# Construct the actual WPF tree without showing a window or running any action.
$source=$source.Replace('$PSScriptRoot',("'"+$root.Replace("'","''")+"'"))
$source=$source.Replace('$window.ShowDialog() | Out-Null','')
$fixture=Join-Path $root ('dist\ui-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$source=$source.Replace('try { Refresh-Replays } catch { Show-Error $_ }',("`$configFile='"+(Join-Path $fixture 'settings.json')+"'`ntry { Refresh-Replays } catch { Show-Error `$_ }"))
. ([ScriptBlock]::Create($source))
$timer.Stop();$updateTimer.Stop()
try {
 $settings.language='en';Set-LauncherLanguage
 if($ui.Help.Content -ne 'Controls' -or $ui.Launch.Content -ne 'Launch game · Auto record'){throw 'English captions failed'}
 if($ui.ReplayList.View.Columns[0].Header -ne 'File'){throw 'English library columns failed'}
 if($ui.ContainsKey('Probe') -or $window.FindName('Probe')){throw 'Obsolete probe button remains'}
 if((Get-LocalizedText 'Steam에 게임 실행을 요청했습니다.') -ne 'Game launch requested through Steam.'){throw 'English status failed'}
 $settings.language='ko';Set-LauncherLanguage
 if($ui.Help.Content -ne '조작키 설명' -or $ui.Launch.Content -ne '게임 실행 · 자동 녹화'){throw 'Korean restoration failed'}
 Write-Output 'PASS: actual WPF construction, English/Korean captions and columns, localized status, probe removal'
} finally { $timer.Stop();$updateTimer.Stop();$window.Close() }
