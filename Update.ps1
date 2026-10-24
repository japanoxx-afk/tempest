param([string]$Target,[string]$Source,[int]$WaitPid,[string]$CurrentVersion,[string]$StatusPath,[switch]$Check,[switch]$NoRestart,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
function Write-UpdateState([string]$State,[string]$Message) {
 if(-not $StatusPath){return}
 $statusDirectory=Split-Path $StatusPath -Parent
 New-Item -ItemType Directory -Path $statusDirectory -Force | Out-Null
 $json=@{state=$State;message=$Message;time=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress
 # PS 5.1 Get-Content defaults to ANSI without a BOM. Keep old launchers compatible.
 [IO.File]::WriteAllText($StatusPath+'.tmp',$json,(New-Object Text.UTF8Encoding($true)))
 if([IO.File]::Exists($StatusPath)){[IO.File]::Replace($StatusPath+'.tmp',$StatusPath,[NullString]::Value)}
 else{[IO.File]::Move($StatusPath+'.tmp',$StatusPath)}
 Add-Content -LiteralPath ($StatusPath+'.log') -Value ($State+': '+$Message) -Encoding UTF8
}
function Get-UpdateFiles([string]$Package) {
 foreach($required in @('Launcher.ps1','Start.cmd','version.json','Update.ps1','Bridge.ps1','ReplayBridge\Scripts\main.lua','ReplayBridge\Scripts\Movement.lua','ReplayBridge\WatchExit.ps1')) {
  if(-not (Test-Path -LiteralPath (Join-Path $Package $required) -PathType Leaf)){throw "배포 파일 누락: $required"}
 }
 foreach($name in @('Launcher.ps1','Start.cmd','version.json','Update.ps1','Bridge.ps1','README.md','ReplayBridge','vendor','docs')) {
  $path=Join-Path $Package $name
  if(Test-Path -LiteralPath $path -PathType Leaf){$name}
  elseif(Test-Path -LiteralPath $path -PathType Container){
   foreach($file in Get-ChildItem -LiteralPath $path -Recurse -File){$file.FullName.Substring($Package.TrimEnd('\').Length+1)}
  }
 }
}
function Install-LauncherUpdate([string]$Package,[string]$Destination,[string]$Backup) {
 $Package=[IO.Path]::GetFullPath($Package).TrimEnd('\')
 $Destination=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
 if($Package -eq $Destination){throw '업데이트 원본과 설치 폴더가 같습니다.'}
 $files=@(Get-UpdateFiles $Package)
 New-Item -ItemType Directory -Path $Destination,$Backup -Force | Out-Null
 $existed=@{};$attempted=New-Object Collections.Generic.List[string]
 foreach($relative in $files){
  $old=Join-Path $Destination $relative
  if(Test-Path -LiteralPath $old -PathType Leaf){
   $saved=Join-Path $Backup $relative
   New-Item -ItemType Directory -Path (Split-Path $saved -Parent) -Force | Out-Null
   Copy-Item -LiteralPath $old -Destination $saved -Force
   $existed[$relative]=$true
  }
 }
 try {
  foreach($relative in $files){
   $dest=Join-Path $Destination $relative
   New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
   $attempted.Add($relative)
   Copy-Item -LiteralPath (Join-Path $Package $relative) -Destination $dest -Force
  }
 } catch {
  foreach($relative in $attempted){
   $dest=Join-Path $Destination $relative
   if($existed[$relative]){Copy-Item -LiteralPath (Join-Path $Backup $relative) -Destination $dest -Force}
   elseif(Test-Path -LiteralPath $dest -PathType Leaf){Remove-Item -LiteralPath $dest -Force}
  }
  throw
 }
}
function Receive-LauncherUpdate([string]$Stage,[string]$InstalledVersion) {
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 Write-UpdateState 'checking' 'GitHub에서 최신 버전을 확인합니다…'
 $release=Invoke-RestMethod 'https://api.github.com/repos/japanoxx-afk/tempest/releases/latest' -Headers @{'User-Agent'='TempestReplayLauncher'} -TimeoutSec 20
 $latest=[version]($release.tag_name -replace '^v','')
 if($latest -le [version]$InstalledVersion){return $null}
 $zip=@($release.assets | Where-Object name -eq 'TempestReplayLauncher.zip')
 $hash=@($release.assets | Where-Object name -eq 'TempestReplayLauncher.zip.sha256')
 if($zip.Count -ne 1 -or $hash.Count -ne 1){throw '릴리스의 배포 파일 또는 체크섬이 없습니다.'}
 New-Item -ItemType Directory -Path $Stage -Force | Out-Null
 Write-UpdateState 'downloading' "v$latest 다운로드 중…"
 $archive=Join-Path $Stage 'update.zip';$checksum=Join-Path $Stage 'update.zip.sha256'
 Invoke-WebRequest $zip[0].browser_download_url -OutFile $archive -UseBasicParsing -TimeoutSec 120
 Invoke-WebRequest $hash[0].browser_download_url -OutFile $checksum -UseBasicParsing -TimeoutSec 20
 Write-UpdateState 'verifying' '다운로드 검증 및 압축 해제 중…'
 # GitHub serves .sha256 as application/octet-stream; PS 5.1 Content is byte[].
 $expected=([IO.File]::ReadAllText($checksum).Trim() -split '\s+')[0]
 if($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected){throw '업데이트 SHA256 검증에 실패했습니다.'}
 $package=Join-Path $Stage 'files'
 Expand-Archive -LiteralPath $archive -DestinationPath $package -Force
 Get-UpdateFiles $package | Out-Null
 if([version](Get-Content -LiteralPath (Join-Path $package 'version.json') -Raw | ConvertFrom-Json).version -ne $latest){throw '릴리스 버전과 배포 버전이 다릅니다.'}
 return $package
}
if($LibraryOnly){return}
$installStarted=$false
try {
 if(-not $Target){throw '설치 폴더가 지정되지 않았습니다.'}
 if($Check){
  $Source=Receive-LauncherUpdate (Join-Path (Split-Path $StatusPath -Parent) 'download') $CurrentVersion
  if(-not $Source){Write-UpdateState 'current' '이미 최신 버전입니다.';return}
  Write-UpdateState 'ready' '검증 완료. 런처를 닫고 업데이트를 설치합니다…'
 }
 $installStarted=$true
 if($WaitPid -and (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)){
  try{Wait-Process -Id $WaitPid -Timeout 60 -ErrorAction Stop}
  catch{if(Get-Process -Id $WaitPid -ErrorAction SilentlyContinue){throw}}
 }
 Write-UpdateState 'installing' '업데이트 설치 중…'
 Install-LauncherUpdate $Source $Target (Join-Path (Split-Path $Source -Parent) 'backup')
 Write-UpdateState 'complete' '업데이트 설치 완료. 런처를 다시 실행합니다.'
 if(-not $NoRestart){Start-Process -FilePath (Join-Path $Target 'Start.cmd') -WorkingDirectory $Target -WindowStyle Hidden}
} catch {
 $failure="업데이트 실패: $($_.Exception.Message)"
 Write-UpdateState 'error' $failure
 if(-not $Check -or $installStarted){Add-Type -AssemblyName PresentationFramework;[Windows.MessageBox]::Show($failure,'런처 업데이트') | Out-Null}
 exit 1
}
