param([Parameter(Mandatory=$true)][string]$Target,[Parameter(Mandatory=$true)][string]$Source,[int]$WaitPid)
$ErrorActionPreference = 'Stop'
try {
 if ($WaitPid) { Wait-Process -Id $WaitPid -Timeout 30 -ErrorAction SilentlyContinue }
 $files = @('Launcher.ps1','Start.cmd','version.json','Update.ps1','Bridge.ps1','README.md','ReplayBridge')
 $backup = Join-Path (Split-Path $Source -Parent) 'backup'
 New-Item $backup -ItemType Directory -Force | Out-Null
 foreach ($file in $files) { if (Test-Path (Join-Path $Target $file)) { Copy-Item (Join-Path $Target $file) $backup -Recurse } }
 try { foreach ($file in $files) { Copy-Item (Join-Path $Source $file) $Target -Force -Recurse } }
 catch { Get-ChildItem $backup | Copy-Item -Destination $Target -Force -Recurse; throw }
 Start-Process (Join-Path $Target 'Start.cmd') -WindowStyle Hidden
} catch {
 Add-Type -AssemblyName PresentationFramework
 [Windows.MessageBox]::Show("업데이트 실패: $($_.Exception.Message)") | Out-Null
}
