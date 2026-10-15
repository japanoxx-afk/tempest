$ErrorActionPreference='Stop'
$version=(Get-Content (Join-Path $PSScriptRoot 'version.json') -Raw | ConvertFrom-Json).version
$stage=Join-Path $PSScriptRoot ('dist\package-'+[guid]::NewGuid().ToString('N'))
New-Item $stage -ItemType Directory -Force | Out-Null
$files=@('Launcher.ps1','Start.cmd','Update.ps1','Bridge.ps1','ReplayBridge','version.json','README.md','docs')
foreach ($file in $files) { Copy-Item (Join-Path $PSScriptRoot $file) $stage -Recurse }
# v0.1.0's updater copies a fixed list of five files. Embed bridge resources in
# the entry script so a direct update from that release can still start.
$bootstrap=@('$script:BridgeSourceRoot=Join-Path $env:LOCALAPPDATA ''TempestReplayLauncher\payload\'+$version+'''')
foreach ($resource in @('Bridge.ps1','ReplayBridge\Scripts\main.lua','ReplayBridge\README.md')) {
 $base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $resource)))
 $parent=Split-Path $resource -Parent
 $bootstrap+='New-Item -ItemType Directory -Path (Join-Path $script:BridgeSourceRoot '''+$parent+''') -Force | Out-Null'
 $bootstrap+='[IO.File]::WriteAllBytes((Join-Path $script:BridgeSourceRoot '''+$resource+'''),[Convert]::FromBase64String('''+$base64+'''))'
}
$launcher=[IO.File]::ReadAllText((Join-Path $stage 'Launcher.ps1'))
$launcher=$launcher.Replace('# RELEASE_PAYLOAD',($bootstrap -join "`r`n"))
[IO.File]::WriteAllText((Join-Path $stage 'Launcher.ps1'),$launcher,(New-Object Text.UTF8Encoding($true)))
$archive=Join-Path $PSScriptRoot 'dist\TempestReplayLauncher.zip'
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -Force
(Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() | Set-Content ($archive+'.sha256') -Encoding ascii
Write-Output $archive
