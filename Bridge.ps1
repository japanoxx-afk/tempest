function Get-BridgePaths([string]$GamePath) {
 $bin = Join-Path $GamePath 'Tempest\Binaries\Win64'
 @{ Bin=$bin; Loader=(Join-Path $bin 'dwmapi.dll'); Runtime=(Join-Path $bin 'ue4ss'); Data=(Join-Path $env:LOCALAPPDATA 'TempestReplayLauncher\bridge') }
}
function Install-ReplayBridge([string]$GamePath) {
 if (Get-Process -Name 'Tempest-Win64-Shipping','Tempest' -ErrorAction SilentlyContinue) { throw '게임을 완전히 종료한 다음 모드를 설치하세요.' }
 $p=Get-BridgePaths $GamePath
 if (-not (Test-Path -LiteralPath (Join-Path $p.Bin 'Tempest-Win64-Shipping.exe'))) { throw '게임 실행 파일이 없습니다.' }
 $marker=Join-Path $p.Runtime 'tempest-launcher-owned.json'
 if ((Test-Path $p.Loader) -or (Test-Path $p.Runtime)) {
  if (-not (Test-Path $marker)) { throw '기존 모드 로더가 있습니다. 자동으로 덮어쓰지 않습니다.' }
  throw '이미 설치되어 있습니다. 기존 브리지 제거 후 다시 설치하세요.'
 }
 $stage=Join-Path $env:LOCALAPPDATA ('TempestReplayLauncher\downloads\'+[guid]::NewGuid())
 New-Item $stage -ItemType Directory -Force | Out-Null
 $assetName='UE4SS_v3.0.1-1176-g1ba38db4.zip'
 $expected='e615ee7a2c24344ea5aeef85183d6cfd550f4f6352225976679f9fefffd0b9a5'
 $archive=Join-Path $stage 'ue4ss.zip'
 Invoke-WebRequest "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental-latest/$assetName" -OutFile $archive -UseBasicParsing -TimeoutSec 120
 if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $expected) { throw 'UE4SS 체크섬 불일치. 설치하지 않았습니다.' }
 $unpack=Join-Path $stage 'files'; Expand-Archive $archive $unpack
 $runtime=Join-Path $unpack 'ue4ss'
 # Disable all bundled gameplay/console mods; install only our bridge and UEHelpers.
 [IO.File]::WriteAllText((Join-Path $runtime 'Mods\mods.json'),'[{"mod_name":"TempestReplayBridge","mod_enabled":true}]')
 [IO.File]::WriteAllText((Join-Path $runtime 'Mods\mods.txt'),"TempestReplayBridge : 1`n")
 $mod=Join-Path $runtime 'Mods\TempestReplayBridge'
 Copy-Item (Join-Path $script:BridgeSourceRoot 'ReplayBridge') $mod -Recurse
 @{asset=$assetName;sha256=$expected;installed=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $runtime 'tempest-launcher-owned.json') -Encoding UTF8
 Copy-Item $runtime $p.Runtime -Recurse
 try { Copy-Item (Join-Path $unpack 'dwmapi.dll') $p.Loader } catch { throw "프록시 설치 실패. ue4ss 폴더는 남아 있습니다: $($_.Exception.Message)" }
 New-Item $p.Data -ItemType Directory -Force | Out-Null
}
function Remove-ReplayBridge([string]$GamePath) {
 if (Get-Process -Name 'Tempest-Win64-Shipping','Tempest' -ErrorAction SilentlyContinue) { throw '게임 종료 후 제거하세요.' }
 $p=Get-BridgePaths $GamePath
 if (-not (Test-Path (Join-Path $p.Runtime 'tempest-launcher-owned.json'))) { throw '이 런처가 설치한 모드가 아닙니다.' }
 # Preserve everything in a timestamped backup instead of deleting a mod directory.
 $backup=Join-Path $p.Bin ('TempestReplayBridge-backup-'+[guid]::NewGuid().ToString('N'))
 New-Item $backup -ItemType Directory | Out-Null
 if (Test-Path $p.Loader) { Move-Item -LiteralPath $p.Loader -Destination (Join-Path $backup 'dwmapi.dll') }
 Move-Item -LiteralPath $p.Runtime -Destination (Join-Path $backup 'ue4ss')
 if (Test-Path (Join-Path $p.Data 'request.txt')) { Remove-Item -LiteralPath (Join-Path $p.Data 'request.txt') }
 $config=Join-Path $env:LOCALAPPDATA 'Tempest\Saved\Config\Windows\Engine.ini'
 if (Test-Path -LiteralPath $config) {
  $text=[IO.File]::ReadAllText($config)
  $updated=[regex]::Replace($text,'(?ms)^; BEGIN TempestReplayLauncher\r?\n.*?^; END TempestReplayLauncher\r?\n?','')
  if ($text -ne $updated) { [IO.File]::WriteAllText($config,$updated,(New-Object Text.UTF8Encoding($false))) }
 }
}
function Initialize-ReplayConfig([string]$ConfigPath=(Join-Path $env:LOCALAPPDATA 'Tempest\Saved\Config\Windows\Engine.ini')) {
 $content=if (Test-Path -LiteralPath $ConfigPath) { [IO.File]::ReadAllText($ConfigPath) } else { '' }
 if ($content -match 'DefName\s*=\s*"DemoNetDriver"') { return }
 $backupRoot=Join-Path $env:LOCALAPPDATA 'TempestReplayLauncher\config-backups'
 New-Item $backupRoot -ItemType Directory -Force | Out-Null
 if (Test-Path -LiteralPath $ConfigPath) { Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $backupRoot ('Engine-'+[guid]::NewGuid().ToString('N')+'.ini')) }
 New-Item (Split-Path $ConfigPath -Parent) -ItemType Directory -Force | Out-Null
 $block=@'
; BEGIN TempestReplayLauncher
[/Script/Engine.GameEngine]
+NetDriverDefinitions=(DefName="DemoNetDriver",DriverClassName="/Script/Engine.DemoNetDriver",DriverClassNameFallback="/Script/Engine.DemoNetDriver")
; END TempestReplayLauncher
'@
 [IO.File]::WriteAllText($ConfigPath,($content.TrimEnd()+"`r`n`r`n"+$block+"`r`n"),(New-Object Text.UTF8Encoding($false)))
}
function Start-BridgeSession([string]$GamePath,[ValidateSet('probe','record','play')][string]$Mode,[string]$Replay='') {
 if (Get-Process -Name 'Tempest-Win64-Shipping','Tempest' -ErrorAction SilentlyContinue) { throw '새 브리지 세션을 시작하려면 게임을 먼저 종료하세요.' }
 $p=Get-BridgePaths $GamePath
 if (-not (Test-Path (Join-Path $p.Runtime 'Mods\TempestReplayBridge\Scripts\main.lua'))) { throw '먼저 실험 모드를 설치하세요.' }
 if (-not (Test-Path (Join-Path $p.Runtime 'tempest-launcher-owned.json'))) { throw '이 런처가 설치한 모드가 아닙니다.' }
 # Update the Lua bridge on the next clean launch; never reload into a live match.
 foreach ($scriptFile in @('main.lua','Movement.lua','ReplayAudio.lua')) {
  Copy-Item (Join-Path $script:BridgeSourceRoot ('ReplayBridge\Scripts\'+$scriptFile)) (Join-Path $p.Runtime ('Mods\TempestReplayBridge\Scripts\'+$scriptFile)) -Force
 }
 # Register DemoNetDriver in the live engine from Lua. User generated INI
 # overrides were observed to be discarded by this game's startup config pass.
 if ($Replay -and $Replay -notmatch '^[a-zA-Z0-9_-]+$') { throw '리플레이 파일명에 지원하지 않는 문자가 있습니다.' }
 $steamExe=$null
 if ($Mode -eq 'play') {
  $steamExe=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe
  if (-not $steamExe -or -not (Test-Path -LiteralPath $steamExe)) { throw 'Steam 실행 파일을 찾을 수 없습니다.' }
 }
 New-Item $p.Data -ItemType Directory -Force | Out-Null
 $session=[guid]::NewGuid().ToString('N')
 $expires=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+120
 [IO.File]::WriteAllText((Join-Path $p.Data 'request.tmp'),"$Mode`n$session`n$expires`n$Replay`n")
 Move-Item -LiteralPath (Join-Path $p.Data 'request.tmp') -Destination (Join-Path $p.Data 'request.txt') -Force
 if ($Mode -eq 'play') {
  $watcher=Join-Path $script:BridgeSourceRoot 'ReplayBridge\WatchExit.ps1'
  $gameExe=Join-Path $GamePath 'Tempest\Binaries\Win64\Tempest-Win64-Shipping.exe'
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$watcher+'"'),'-GameExecutable',('"'+$gameExe+'"'),'-Data',('"'+$p.Data+'"'),'-Session',$session,'-ApplyReplayGuard')
  # The game's BP_HUD_MainMenu.SkipIntro checks the command line for NoIntro.
  # Pass it for this replay process only; do not edit persistent Steam options.
  Start-Process -FilePath $steamExe -ArgumentList @('-applaunch','1486920','-NoIntro') -WindowStyle Hidden
 } else {
  Start-Process 'steam://rungameid/1486920'
 }
 return $session
}
