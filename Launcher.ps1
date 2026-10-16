$ErrorActionPreference = 'Stop'
$script:BridgeSourceRoot=$PSScriptRoot
# RELEASE_PAYLOAD
Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
. (Join-Path $script:BridgeSourceRoot 'Bridge.ps1')
$data = Join-Path $env:LOCALAPPDATA 'TempestReplayLauncher'
New-Item $data -ItemType Directory -Force | Out-Null
$configFile = Join-Path $data 'settings.json'
$settings = @{ autoRecord = $true; game = 'C:\Program Files (x86)\Steam\steamapps\common\Tempest Rising'; replays = (Join-Path $env:LOCALAPPDATA 'Tempest\Saved\Demos') }
if (Test-Path $configFile) { try { $c = Get-Content $configFile -Raw | ConvertFrom-Json; $settings.game = $c.game; $settings.replays = $c.replays } catch {} }
$version = (Get-Content (Join-Path $root 'version.json') -Raw | ConvertFrom-Json).version
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="TEMPEST · Replay Launcher" Width="960" Height="800" MinWidth="900" MinHeight="760" Background="#101820" Foreground="#E6EDF3" WindowStartupLocation="CenterScreen">
 <Window.Resources><Style TargetType="Button"><Setter Property="Margin" Value="4"/><Setter Property="Padding" Value="14,9"/><Setter Property="Background" Value="#B9E873"/><Setter Property="Foreground" Value="#101820"/></Style><Style TargetType="TextBox"><Setter Property="Margin" Value="4"/><Setter Property="Padding" Value="8"/></Style></Window.Resources>
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <DockPanel><Button Name="Update" DockPanel.Dock="Right" Content="런처 업데이트"/><StackPanel><TextBlock Text="TEMPEST" FontSize="30" FontWeight="Bold" Foreground="#B9E873"/><TextBlock Name="Version"/></StackPanel></DockPanel>
 <StackPanel Grid.Row="1" Margin="0,18,0,8"><TextBlock Text="게임 설치 폴더"/><DockPanel><Button Name="BrowseGame" DockPanel.Dock="Right" Content="찾기"/><TextBox Name="GamePath"/></DockPanel><TextBlock Text="리플레이 폴더"/><DockPanel><Button Name="BrowseReplay" DockPanel.Dock="Right" Content="찾기"/><TextBox Name="ReplayPath"/></DockPanel></StackPanel>
 <TextBlock Grid.Row="2" Text="리플레이 라이브러리 · .replay" FontSize="18" Margin="4,6"/>
 <ListView Grid.Row="3" Name="ReplayList" Background="#1B2935" Foreground="White" Margin="4"><ListView.View><GridView><GridViewColumn Header="파일" DisplayMemberBinding="{Binding Name}" Width="380"/><GridViewColumn Header="수정 시간" DisplayMemberBinding="{Binding LastWriteTime}" Width="200"/><GridViewColumn Header="바이트" DisplayMemberBinding="{Binding Length}" Width="100"/></GridView></ListView.View></ListView>
 <StackPanel Grid.Row="4"><WrapPanel><Button Name="Launch" Content="게임 실행 · 자동 녹화"/><Button Name="Refresh" Content="새로고침 / 경로 저장"/><Button Name="Import" Content="리플레이 가져오기"/><Button Name="Open" Content="폴더 열기"/></WrapPanel><WrapPanel><Button Name="InstallBridge" Content="녹화·재생 모드 설치"/><Button Name="RemoveBridge" Content="녹화·재생 모드 제거"/><Button Name="Probe" Content="호환성 진단 실행"/><Button Name="Diagnostics" Content="진단 폴더 열기"/></WrapPanel><TextBlock Text="자동 녹화 · 관전자 재생 기본 적용 (녹화·재생 모드 설치 필요)" Margin="4,8" Foreground="#B9E873"/><Button Name="Play" Content="선택 리플레이 관전자 재생" HorizontalAlignment="Left"/><TextBlock Text="기록 범위: 내 클라이언트가 수신한 정보만 저장 · 시야 밖 적 이동은 누락될 수 있음 / 인터넷 상대 경기 확인 필요 · 시간 탐색 미지원 · 마우스 가장자리·미니맵 이동 / U HUD 숨기기·표시 / I 자원 UI / Q·W·E·R·T·Y·A·S 통계 항목 / C 선택 대상 추적 / F6 본진 / F7 배속 / F8 일시정지" TextWrapping="Wrap" Margin="4,8" Foreground="#FFC778"/><WrapPanel><TextBlock Text="리플레이 속도" VerticalAlignment="Center" Margin="4"/><ComboBox Name="PlaybackSpeed" SelectedIndex="1" Width="90" Margin="4"><ComboBoxItem Content="0.5x" Tag="0.5"/><ComboBoxItem Content="1x" Tag="1"/><ComboBoxItem Content="2x" Tag="2"/><ComboBoxItem Content="4x" Tag="4"/></ComboBox><Button Name="ApplySpeed" Content="리플레이 배속 적용"/></WrapPanel><TextBlock Name="MovementStatus" TextWrapping="Wrap" Margin="4" Foreground="#B9E873"/><TextBlock Name="BridgeStatus" TextWrapping="Wrap" Margin="4,4" Foreground="#B9E873"/></StackPanel>
 <TextBlock Grid.Row="5" Name="Status" TextWrapping="Wrap" Margin="4,12,4,0" Foreground="#A8B7C5"/>
 </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
@('Update','Version','GamePath','ReplayPath','BrowseGame','BrowseReplay','ReplayList','Launch','Refresh','Import','Open','Play','Status','InstallBridge','RemoveBridge','Probe','Diagnostics','BridgeStatus','PlaybackSpeed','ApplySpeed','MovementStatus') | ForEach-Object { $ui[$_] = $window.FindName($_) }
$ui.Version.Text = "Replay Launcher v$version"
$ui.GamePath.Text = $settings.game
$ui.ReplayPath.Text = $settings.replays
function Show-Error($e) { $ui.Status.Text = $e.Exception.Message }
function Save-Paths {
 if (-not [IO.Path]::IsPathRooted($ui.GamePath.Text) -or -not [IO.Path]::IsPathRooted($ui.ReplayPath.Text)) { throw '절대 경로를 입력하세요.' }
 $settings.game = $ui.GamePath.Text; $settings.replays = $ui.ReplayPath.Text; $settings.autoRecord = $true
 $settings | ConvertTo-Json | Set-Content $configFile -Encoding UTF8
}
$script:librarySignature=$null
function Sync-ReplayLibrary([bool]$SelectNewest=$false) {
 $folder=$ui.ReplayPath.Text
 $files=@(if (Test-Path -LiteralPath $folder -PathType Container) { Get-ChildItem -LiteralPath $folder -Filter '*.replay' -File | Sort-Object LastWriteTime -Descending })
 $signature=$folder+'|'+(($files | ForEach-Object { $_.Name+':'+$_.Length+':'+$_.LastWriteTimeUtc.Ticks }) -join '|')
 if ($signature -ne $script:librarySignature) {
  $selectedPath=if ($ui.ReplayList.SelectedItem) { $ui.ReplayList.SelectedItem.FullName } else { $null }
  $ui.ReplayList.ItemsSource=$files
  $ui.ReplayList.SelectedItem=@($files | Where-Object FullName -eq $selectedPath | Select-Object -First 1)[0]
  $script:librarySignature=$signature
 }
 if ($files.Count -gt 0 -and ($SelectNewest -or -not $ui.ReplayList.SelectedItem)) { $ui.ReplayList.SelectedItem=$files[0] }
}
function Get-RecordingFileMessage([string]$Detail,[string]$Folder=(Join-Path $env:LOCALAPPDATA 'Tempest\Saved\Demos')) {
 $name=($Detail -split ';')[0]
 if ($name -notmatch '^Tempest_[A-Za-z0-9_-]+$') { return '기록 파일 이름 확인 필요' }
 $file=Join-Path $Folder ($name+'.replay')
 if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '기록 파일 없음 · 녹화 성공 아님' }
 $item=Get-Item -LiteralPath $file
 if ($item.Length -eq 0) { return '빈 기록 파일 · 녹화 성공 아님' }
 return "저장 파일 확인: $($item.Name) · $($item.Length) 바이트 · $file (재생 검증 필요)"
}
function Refresh-Replays {
 Save-Paths
 Sync-ReplayLibrary
 $ui.Status.Text = "리플레이 $($ui.ReplayList.Items.Count)개 · 목록은 2초마다 자동 갱신됩니다."
}
function Browse-Path($target) {
 $dialog = New-Object Windows.Forms.FolderBrowserDialog
 if ($dialog.ShowDialog() -eq 'OK') { $target.Text = $dialog.SelectedPath }
 $dialog.Dispose()
}
$ui.BrowseGame.Add_Click({ Browse-Path $ui.GamePath })
$ui.BrowseReplay.Add_Click({ Browse-Path $ui.ReplayPath })
$ui.Refresh.Add_Click({ try { Refresh-Replays } catch { Show-Error $_ } })
$ui.Open.Add_Click({ try { Save-Paths; New-Item -ItemType Directory -Path $settings.replays -Force | Out-Null; Start-Process explorer.exe -ArgumentList ('"' + $settings.replays + '"') } catch { Show-Error $_ } })
$script:bridgeSession=$null
$script:bridgeStarted=$null
function Begin-Bridge($mode,$name='') {
 $script:bridgeMode=$mode
 $script:bridgeSession=Start-BridgeSession $settings.game $mode $name
 $script:bridgeStarted=Get-Date
 $ui.BridgeStatus.Text='게임 브리지 응답 대기 중… 아직 녹화되지 않았습니다.'
}
$ui.Launch.Add_Click({ try { Save-Paths; if (-not (Test-Path -LiteralPath (Join-Path $settings.game 'Tempest.exe'))) { throw 'Tempest.exe를 찾을 수 없습니다.' }; Begin-Bridge 'record'; $ui.Status.Text = 'Steam에 게임 실행을 요청했습니다.' } catch { Show-Error $_ } })
$ui.InstallBridge.Add_Click({ try { Save-Paths; $ui.InstallBridge.IsEnabled=$false; Install-ReplayBridge $settings.game; $ui.Status.Text='녹화·재생 모드 설치 완료. 게임 실행 버튼을 누르면 경기 시작 시 자동 녹화를 시도합니다.' } catch { Show-Error $_ } finally { $ui.InstallBridge.IsEnabled=$true } })
$ui.RemoveBridge.Add_Click({ try { Save-Paths; Remove-ReplayBridge $settings.game; $ui.Status.Text='모드를 백업 폴더로 이동해 비활성화했습니다.' } catch { Show-Error $_ } })
$ui.Probe.Add_Click({ try { Save-Paths; Begin-Bridge 'probe' } catch { Show-Error $_ } })
$ui.Diagnostics.Add_Click({ try { $p=Get-BridgePaths $settings.game; New-Item $p.Data -ItemType Directory -Force | Out-Null; Start-Process explorer.exe -ArgumentList ('"'+$p.Data+'"') } catch { Show-Error $_ } })
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
 try {
  Sync-ReplayLibrary
  if (-not $script:bridgeSession) { return }
  $p=Get-BridgePaths $settings.game
  $movementFile=Join-Path $p.Data 'movement-state.txt'
  $movement=@(if (Test-Path -LiteralPath $movementFile) { Get-Content -LiteralPath $movementFile -Encoding UTF8 })
  $ui.MovementStatus.Text=''
  if ($movement.Count -ge 5 -and $movement[0] -eq $script:bridgeSession -and $movement[2] -in @('recording','playing','completed')) {
   $action=if ($movement[2] -eq 'recording') {'기록'} elseif ($movement[2] -eq 'completed') {'기록 완료'} else {'재생'}
   $ui.MovementStatus.Text="유닛 이동 $action · $($movement[3]) · $($movement[4]) · $($movement[1]).movement"
  }
  $statusFile=Join-Path $p.Data 'status.txt'
  $lines=@(if (Test-Path $statusFile) { Get-Content $statusFile -Encoding UTF8 })
  if ($lines.Count -ge 4 -and $lines[0] -eq $script:bridgeSession) {
   $labels=@{record_waiting='녹화 미시작 · 경기 시작 판정 대기';record_not_started='이 경기 녹화 안 됨 · 시작 판정 확인 필요';record_requested='녹화 명령 전송 · 성공 확인 중';record_driver_active='기록 드라이버 활성 · 파일 확인 필요';record_failed='녹화 실패 · 기록 드라이버가 생성되지 않음';record_session_left='경기 화면 종료 · 아래 기록 결과 확인';bridge_error='브리지 오류';probe_ready='진단 준비 완료';viewer_initializing='관전자 HUD·카메라 연결됨';play_requested='리플레이 로딩 요청';viewer_finished='리플레이 종료';animation_error='보병 모션 보정 오류';movement_recording='유닛 이동 보조 기록 중';movement_playback='유닛 이동 보조 파일 재생 중';movement_missing='이동 보조 파일 없음 · 기본 재생';movement_error='유닛 이동 보조 기록/재생 오류'}
   $label=if ($labels.ContainsKey($lines[2])) { $labels[$lines[2]] } else { $lines[2] }
   $ui.BridgeStatus.Text="브리지: $label · $($lines[3])"
   if ($lines[2] -in @('record_requested','record_driver_active','record_session_left')) {
    $ui.BridgeStatus.Text += ' · '+(Get-RecordingFileMessage $lines[3])
    if ($lines[2] -eq 'record_session_left') { Sync-ReplayLibrary $true }
   }
  } elseif (((Get-Date)-$script:bridgeStarted).TotalSeconds -gt 120) { $ui.BridgeStatus.Text='브리지 응답 없음. 진단 로그를 확인하세요. 녹화되지 않았을 수 있습니다.' }
 } catch { $ui.BridgeStatus.Text=$_.Exception.Message }
})
$timer.Start()
$window.Add_Closed({ $timer.Stop() })
function Import-ReplayFiles([string]$Source,[string]$Folder) {
 $destination=Join-Path $Folder ([IO.Path]::GetFileName($Source))
 $companion=[IO.Path]::ChangeExtension($Source,'.movement')
 $targetCompanion=[IO.Path]::ChangeExtension($destination,'.movement')
 if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $targetCompanion)) { throw '같은 이름의 리플레이 또는 이동 파일이 이미 있습니다. 원본을 유지합니다.' }
 New-Item -ItemType Directory -Path $Folder -Force | Out-Null
 [IO.File]::Copy($Source,$destination,$false)
 if (Test-Path -LiteralPath $companion -PathType Leaf) {
  try { [IO.File]::Copy($companion,$targetCompanion,$false) }
  catch { Remove-Item -LiteralPath $destination;throw }
 }
 return $destination
}
$ui.Import.Add_Click({
 try {
  Save-Paths; $dialog = New-Object Windows.Forms.OpenFileDialog; $dialog.Filter = 'Unreal replay (*.replay)|*.replay'
  if ($dialog.ShowDialog() -eq 'OK') {
   Import-ReplayFiles $dialog.FileName $settings.replays | Out-Null; Refresh-Replays
  }; $dialog.Dispose()
 } catch { Show-Error $_ }
})
function Start-SelectedReplay {
 try {
  Save-Paths; $replay = $ui.ReplayList.SelectedItem
  if (-not $replay) { throw '재생할 파일을 선택하세요.' }
  $name = [IO.Path]::GetFileNameWithoutExtension($replay.Name)
  if ($name -notmatch '^[a-zA-Z0-9_-]+$') { throw '실험적 재생 파일명은 영문, 숫자, 밑줄, 하이픈만 사용할 수 있습니다.' }
  $default = Join-Path $env:LOCALAPPDATA 'Tempest\Saved\Demos'
  if ([IO.Path]::GetFullPath($settings.replays).TrimEnd('\') -ne [IO.Path]::GetFullPath($default)) { throw '실험적 재생에는 기본 폴더 %LOCALAPPDATA%\Tempest\Saved\Demos를 사용하세요.' }
  if (Get-Process -Name 'Tempest-Win64-Shipping','Tempest' -ErrorAction SilentlyContinue) { throw '게임을 먼저 종료하세요.' }
  if (-not (Test-Path -LiteralPath (Join-Path $settings.game 'Tempest.exe'))) { throw '게임 경로를 확인하세요.' }
  Begin-Bridge 'play' $name
  $ui.Status.Text = '리플레이를 불러옵니다. 검증 범위: 오프라인 스커미시 / 관전자 HUD·본진·건설 장면.'
 } catch { Show-Error $_ }
}
$ui.Play.Add_Click({ Start-SelectedReplay })
$ui.ReplayList.Add_MouseDoubleClick({
 param($sender,$eventArgs)
 $item=[Windows.Controls.ItemsControl]::ContainerFromElement($ui.ReplayList,$eventArgs.OriginalSource)
 if ($item -is [Windows.Controls.ListViewItem]) {
  Start-SelectedReplay
  $eventArgs.Handled=$true
 }
})
$ui.ApplySpeed.Add_Click({
 try {
  if (-not $script:bridgeSession -or $script:bridgeMode -ne 'play') { throw '리플레이를 먼저 실행하세요. 게임에서는 F7로 배속을 전환할 수 있습니다.' }
  $speed=[string]$ui.PlaybackSpeed.SelectedItem.Tag
  if ($speed -notin @('0.5','1','2','4')) { throw '지원하지 않는 배속입니다.' }
  $p=Get-BridgePaths $settings.game
  [IO.File]::WriteAllText((Join-Path $p.Data 'control.tmp'),"$script:bridgeSession`nspeed=$speed`n")
  Move-Item -LiteralPath (Join-Path $p.Data 'control.tmp') -Destination (Join-Path $p.Data 'control.txt') -Force
  $ui.Status.Text="재생 속도 $($speed)x 적용 요청 · 게임 응답은 브리지 상태에서 확인하세요."
 } catch { Show-Error $_ }
})
$ui.Update.Add_Click({
 try {
  $ui.Update.IsEnabled = $false; $ui.Status.Text = 'GitHub에서 최신 버전을 확인합니다…'
  $release = Invoke-RestMethod 'https://api.github.com/repos/japanoxx-afk/tempest/releases/latest' -Headers @{'User-Agent'='TempestReplayLauncher'} -TimeoutSec 20
  $latest = [version]($release.tag_name -replace '^v','')
  if ($latest -le [version]$version) { $ui.Status.Text = '최신 버전입니다.'; return }
  $asset = @($release.assets | Where-Object name -eq 'TempestReplayLauncher.zip')
  $hash = @($release.assets | Where-Object name -eq 'TempestReplayLauncher.zip.sha256')
  if ($asset.Count -ne 1 -or $hash.Count -ne 1) { throw '릴리스의 배포 파일 또는 체크섬이 없습니다.' }
  if ([Windows.MessageBox]::Show("v$latest 업데이트를 다운로드하고 런처를 재시작할까요?",'런처 업데이트','YesNo') -ne 'Yes') { return }
  $stage = Join-Path $data ([guid]::NewGuid().ToString()); New-Item $stage -ItemType Directory | Out-Null
  Invoke-WebRequest $asset[0].browser_download_url -OutFile (Join-Path $stage 'update.zip') -UseBasicParsing -TimeoutSec 120
  $expected = (Invoke-WebRequest $hash[0].browser_download_url -UseBasicParsing -TimeoutSec 20).Content.Trim().Split(' ')[0]
  if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash (Join-Path $stage 'update.zip') -Algorithm SHA256).Hash -ne $expected) { throw '업데이트 SHA256 검증에 실패했습니다.' }
  Expand-Archive (Join-Path $stage 'update.zip') (Join-Path $stage 'files')
  foreach ($file in @('Launcher.ps1','Start.cmd','version.json','Bridge.ps1','ReplayBridge\Scripts\main.lua')) { if (-not (Test-Path (Join-Path $stage "files\$file"))) { throw "배포 파일 누락: $file" } }
  if ([version](Get-Content (Join-Path $stage 'files\version.json') -Raw | ConvertFrom-Json).version -ne $latest) { throw '릴리스 버전과 배포 버전이 다릅니다.' }
  Copy-Item (Join-Path $root 'Update.ps1') (Join-Path $stage 'Update.ps1')
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $stage 'Update.ps1')+'"'),'-Target',('"'+$root+'"'),'-Source',('"'+(Join-Path $stage 'files')+'"'),'-WaitPid',$PID)
  $window.Close()
 } catch { $ui.Status.Text = "업데이트 확인 실패: $($_.Exception.Message) (아직 릴리스가 없거나 네트워크 오류일 수 있습니다.)" }
 finally { $ui.Update.IsEnabled = $true }
})
try { Refresh-Replays } catch { Show-Error $_ }
$window.ShowDialog() | Out-Null
