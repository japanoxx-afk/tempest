$ErrorActionPreference='Stop'
$script:BridgeSourceRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $script:BridgeSourceRoot 'Bridge.ps1')
$testRoot=Join-Path $script:BridgeSourceRoot ('dist\install-test-'+[guid]::NewGuid().ToString('N'))
$runtime=Join-Path $script:BridgeSourceRoot 'vendor\UE4SS_v3.0.1-1176-g1ba38db4.zip'
function Get-Process {param($Name,$ErrorAction) return $null}
function New-TestGame([string]$Name){
 $game=Join-Path $testRoot $Name
 $bin=Join-Path $game 'Tempest\Binaries\Win64'
 New-Item -ItemType Directory -Path $bin -Force | Out-Null
 [IO.File]::WriteAllBytes((Join-Path $bin 'Tempest-Win64-Shipping.exe'),[byte[]](1))
 return $game
}
function Invoke-WebRequest {throw 'Bundled installation must not use the network'}
$game=New-TestGame 'bundled'
Install-ReplayBridge $game
$paths=Get-BridgePaths $game
foreach($file in @($paths.Loader,(Join-Path $paths.Runtime 'UE4SS.dll'),(Join-Path $paths.Runtime 'LICENSE'),(Join-Path $paths.Runtime 'Mods\TempestReplayBridge\Scripts\main.lua'))){if(-not(Test-Path -LiteralPath $file)){throw "Missing installed runtime file: $file"}}
$marker=Get-Content (Join-Path $paths.Runtime 'tempest-launcher-owned.json') -Raw | ConvertFrom-Json
if($marker.sha256 -ne (Get-FileHash $runtime).Hash){throw 'Installed runtime identity changed'}
$rejected=$false;try{Install-ReplayBridge $game}catch{$rejected=$true}
if(-not $rejected){throw 'Existing loader overwritten'}
'PASS: real pinned ZIP offline install, license, bridge, identity and existing loader protection'
$script:BridgeRuntimeArchive=Join-Path $testRoot 'corrupt.zip'
[IO.File]::WriteAllBytes($script:BridgeRuntimeArchive,[byte[]](1,2,3))
$badGame=New-TestGame 'corrupt'
$rejected=$false;try{Install-ReplayBridge $badGame}catch{$rejected=$true}
if(-not $rejected -or (Test-Path (Get-BridgePaths $badGame).Loader)){throw 'Corrupt runtime was installed'}
'PASS: corrupt bundled archive rejected before installing loader'
$script:BridgeRuntimeArchive=Join-Path $testRoot 'missing.zip'
$script:fallbackUri=$null
function Invoke-WebRequest {param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec)
 $script:fallbackUri=$Uri;Copy-Item -LiteralPath $runtime -Destination $OutFile
}
$fallbackGame=New-TestGame 'fallback'
Install-ReplayBridge $fallbackGame
if($script:fallbackUri -ne 'https://github.com/japanoxx-afk/tempest/releases/download/v0.3.26/UE4SS_v3.0.1-1176-g1ba38db4.zip'){throw 'Fallback must use pinned launcher release asset'}
if(-not (Test-Path (Get-BridgePaths $fallbackGame).Loader)){throw 'Legacy fallback install failed'}
'PASS: legacy missing-vendor fallback uses same pinned and verified runtime'
