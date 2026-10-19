$ErrorActionPreference='Stop'
$watcher=Join-Path (Split-Path $PSScriptRoot -Parent) 'ReplayBridge\WatchExit.ps1'
$exitTestRoot=Join-Path $env:TEMP ('tempest-exit-test-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $exitTestRoot | Out-Null
foreach($case in @('shutdown','stale','no-signal','window-visible','already-exited','terminal-viewer','stale-viewer')) {
 & {
  $session='1234567890abcdef1234567890abcdef'
  $caseData=Join-Path $exitTestRoot $case
  New-Item -ItemType Directory -Path $caseData | Out-Null
  if($case -ne 'no-signal') {
   $value=if($case -eq 'stale'){'old-session'}else{$session}
   [IO.File]::WriteAllText((Join-Path $caseData 'shutdown.txt'),$value)
  }
  $fake=[pscustomobject]@{Path='C:\test\game.exe';StartTime=(Get-Date);HasExited=($case -eq 'already-exited');MainWindowHandle=[IntPtr]::Zero;Killed=$false;WaitMs=0}
  if($case -in @('window-visible','terminal-viewer','stale-viewer')){$fake.MainWindowHandle=[IntPtr]1}
  if($case -in @('terminal-viewer','stale-viewer')){
   $closeValue=if($case -eq 'terminal-viewer'){$session}else{'old-session'}
   [IO.File]::WriteAllText((Join-Path $caseData 'close-viewer.txt'),$closeValue)
  }
  $fake | Add-Member ScriptMethod Refresh {}
  $fake | Add-Member ScriptMethod WaitForExit {param($ms) $this.WaitMs=$ms;return $false}
  $fake | Add-Member ScriptMethod Kill {$this.Killed=$true}
  function Get-Process {param($Name,$ErrorAction) return $fake}
  function Start-Sleep {param($Seconds,$Milliseconds) $fake.HasExited=$true}
  & $watcher -GameExecutable 'C:\test\game.exe' -Data $caseData -Session $session
  if($fake.Killed -ne ($case -in @('shutdown','terminal-viewer'))){throw "Wrong exit-cleanup decision: $case"}
  if($case -eq 'shutdown' -and $fake.WaitMs -ne 8000){throw 'Graceful exit wait missing'}
  if($case -eq 'terminal-viewer' -and $fake.WaitMs -ne 2000){throw 'Terminal viewer exit wait missing'}
 }
}
'PASS: cleanup requires matching shutdown session, closed window and live original process'
