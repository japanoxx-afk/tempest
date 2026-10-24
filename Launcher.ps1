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
$settings = @{ language='ko'; autoRecord = $true; game = 'C:\Program Files (x86)\Steam\steamapps\common\Tempest Rising'; replays = (Join-Path $env:LOCALAPPDATA 'Tempest\Saved\Demos') }
if (Test-Path $configFile) { try { $c = Get-Content $configFile -Raw | ConvertFrom-Json; $settings.game = $c.game; $settings.replays = $c.replays; if($c.language -in @('ko','en')){$settings.language=$c.language} } catch {} }
$version = (Get-Content (Join-Path $root 'version.json') -Raw | ConvertFrom-Json).version
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="TEMPEST · Replay Launcher" Width="960" Height="800" MinWidth="900" MinHeight="760" Background="#101820" Foreground="#E6EDF3" WindowStartupLocation="CenterScreen">
 <Window.Resources><Style TargetType="Button"><Setter Property="Margin" Value="4"/><Setter Property="Padding" Value="14,9"/><Setter Property="Background" Value="#B9E873"/><Setter Property="Foreground" Value="#101820"/></Style><Style TargetType="TextBox"><Setter Property="Margin" Value="4"/><Setter Property="Padding" Value="8"/></Style></Window.Resources>
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <DockPanel><ComboBox Name="Language" DockPanel.Dock="Right" Width="100" Margin="4" VerticalAlignment="Top"><ComboBoxItem Content="한국어" Tag="ko"/><ComboBoxItem Content="English" Tag="en"/></ComboBox><Button Name="Help" DockPanel.Dock="Right" Content="조작키 설명"/><Button Name="Update" DockPanel.Dock="Right" Content="런처 업데이트"/><StackPanel><TextBlock Text="TEMPEST" FontSize="30" FontWeight="Bold" Foreground="#B9E873"/><TextBlock Name="Version"/></StackPanel></DockPanel>
 <StackPanel Grid.Row="1" Margin="0,18,0,8"><TextBlock Name="GameLabel" Text="게임 설치 폴더"/><DockPanel><Button Name="BrowseGame" DockPanel.Dock="Right" Content="찾기"/><TextBox Name="GamePath"/></DockPanel><TextBlock Name="ReplayLabel" Text="리플레이 폴더"/><DockPanel><Button Name="BrowseReplay" DockPanel.Dock="Right" Content="찾기"/><TextBox Name="ReplayPath"/></DockPanel></StackPanel>
 <TextBlock Name="LibraryLabel" Grid.Row="2" Text="리플레이 라이브러리 · .replay" FontSize="18" Margin="4,6"/>
 <ListView Grid.Row="3" Name="ReplayList" Background="#1B2935" Foreground="White" Margin="4"><ListView.View><GridView><GridViewColumn Header="파일" DisplayMemberBinding="{Binding Name}" Width="380"/><GridViewColumn Header="수정 시간" DisplayMemberBinding="{Binding LastWriteTime}" Width="200"/><GridViewColumn Header="바이트" DisplayMemberBinding="{Binding Length}" Width="100"/></GridView></ListView.View></ListView>
 <StackPanel Grid.Row="4"><WrapPanel><Button Name="Launch" Content="게임 실행 · 자동 녹화"/><Button Name="Refresh" Content="새로고침 / 경로 저장"/><Button Name="Import" Content="리플레이 가져오기"/><Button Name="Export" Content="공유 파일 저장"/><Button Name="Open" Content="폴더 열기"/></WrapPanel><WrapPanel><Button Name="InstallBridge" Content="녹화·재생 모드 설치"/><Button Name="RemoveBridge" Content="녹화·재생 모드 제거"/><Button Name="Diagnostics" Content="진단 폴더 열기"/></WrapPanel><TextBlock Name="AutoHint" Text="자동 녹화 · 관전자 재생 기본 적용 (녹화·재생 모드 설치 필요)" Margin="4,8" Foreground="#B9E873"/><Button Name="Play" Content="선택 리플레이 관전자 재생" HorizontalAlignment="Left"/><TextBlock Name="LimitHint" Text="기록 범위: 내 클라이언트가 수신한 정보 · 시간 탐색 미지원. 조작키 설명 버튼에서 재생 조작법을 확인하세요." TextWrapping="Wrap" Margin="4,8" Foreground="#FFC778"/><WrapPanel><TextBlock Name="SpeedLabel" Text="리플레이 속도" VerticalAlignment="Center" Margin="4"/><ComboBox Name="PlaybackSpeed" SelectedIndex="1" Width="90" Margin="4"><ComboBoxItem Content="0.5x" Tag="0.5"/><ComboBoxItem Content="1x" Tag="1"/><ComboBoxItem Content="2x" Tag="2"/><ComboBoxItem Content="4x" Tag="4"/></ComboBox><Button Name="ApplySpeed" Content="리플레이 배속 적용"/></WrapPanel><TextBlock Name="MovementStatus" TextWrapping="Wrap" Margin="4" Foreground="#B9E873"/><TextBlock Name="BridgeStatus" TextWrapping="Wrap" Margin="4,4" Foreground="#B9E873"/></StackPanel>
 <TextBlock Grid.Row="5" Name="Status" TextWrapping="Wrap" Margin="4,12,4,0" Foreground="#A8B7C5"/>
 </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
@('Language','Help','GameLabel','ReplayLabel','LibraryLabel','AutoHint','LimitHint','SpeedLabel','Update','Version','GamePath','ReplayPath','BrowseGame','BrowseReplay','ReplayList','Launch','Refresh','Import','Export','Open','Play','Status','InstallBridge','RemoveBridge','Diagnostics','BridgeStatus','PlaybackSpeed','ApplySpeed','MovementStatus') | ForEach-Object { $ui[$_] = $window.FindName($_) }
$script:english=@{
 'GitHub에서 최신 버전을 확인합니다…'='Checking GitHub for the latest version…';'다운로드 중…'='Downloading…';'다운로드 검증 및 압축 해제 중…'='Verifying download and extracting…'
 '이미 최신 버전입니다.'='The launcher is up to date.';'검증 완료. 런처를 닫고 업데이트를 설치합니다…'='Verified. Closing launcher to install the update…';'업데이트 설치 중…'='Installing update…'
 '업데이트 설치 완료. 런처를 다시 실행합니다.'='Update installed. Restarting launcher.';'업데이트 SHA256 검증에 실패했습니다.'='Update SHA256 verification failed.';'릴리스의 배포 파일 또는 체크섬이 없습니다.'='Release package or checksum is missing.'
 '리플레이 안전 검사 실패 · 게임 빌드와 진단 로그 확인 필요'='Replay safety check failed; check game build and logs'
 '공유 파일 저장'='Export replay ZIP';'공유용 ZIP 저장 완료: '='Replay ZIP saved: ';'이동 보조 파일이 없어 묶음을 만들 수 없습니다.'='The movement companion is missing.';'빈 기록 파일은 공유할 수 없습니다.'='Empty recordings cannot be shared.';'지원하지 않는 리플레이 묶음입니다.'='Unsupported replay package.';'같은 이름의 replay와 movement 두 파일만 들어 있는 ZIP을 선택하세요.'='Choose a ZIP containing only a matching replay and movement pair.'
 '같은 이름의 리플레이 또는 이동 파일이 이미 있습니다. 원본을 유지합니다.'='A replay or companion with this name already exists. Original files were preserved.'
 '실험적 재생 파일명은 영문, 숫자, 밑줄, 하이픈만 사용할 수 있습니다.'='Replay filenames must contain letters, numbers, underscores or hyphens.'
 '실험적 재생에는 기본 폴더 %LOCALAPPDATA%\Tempest\Saved\Demos를 사용하세요.'='Use the default replay folder: %LOCALAPPDATA%\Tempest\Saved\Demos.'
 '최신 버전 확인 중…'='Checking latest version…';'업데이트를 확인합니다…'='Checking for updates…';'런처 업데이트 오류'='Launcher update error';'재생'='Playback';'런처 업데이트'='Update launcher';'조작키 설명'='Controls';'게임 설치 폴더'='Game installation folder';'리플레이 폴더'='Replay folder';'찾기'='Browse'
 '리플레이 라이브러리 · .replay'='Replay library · .replay';'파일'='File';'수정 시간'='Modified';'바이트'='Bytes'
 '게임 실행 · 자동 녹화'='Launch game · Auto record';'새로고침 / 경로 저장'='Refresh / Save paths';'리플레이 가져오기'='Import replay';'폴더 열기'='Open folder'
 '녹화·재생 모드 설치'='Install replay mod';'녹화·재생 모드 제거'='Remove replay mod';'진단 폴더 열기'='Open logs'
 '선택 리플레이 관전자 재생'='Play selected replay';'리플레이 속도'='Playback speed';'리플레이 배속 적용'='Apply speed'
 '자동 녹화 · 관전자 재생 기본 적용 (녹화·재생 모드 설치 필요)'='Automatic recording and spectator playback (replay mod required)'
 '기록 범위: 내 클라이언트가 수신한 정보 · 시간 탐색 미지원. 조작키 설명 버튼에서 재생 조작법을 확인하세요.'='Records information received by your client. Seeking is unsupported. Open Controls for playback shortcuts.'
 '절대 경로를 입력하세요.'='Enter an absolute path.';'재생할 파일을 선택하세요.'='Select a replay.';'게임을 먼저 종료하세요.'='Close the game first.';'게임 경로를 확인하세요.'='Check the game path.'
 'Tempest.exe를 찾을 수 없습니다.'='Tempest.exe was not found.';'Steam에 게임 실행을 요청했습니다.'='Game launch requested through Steam.'
 '게임 브리지 응답 대기 중… 아직 녹화되지 않았습니다.'='Waiting for the game bridge. Recording has not started.'
 '녹화·재생 모드 설치 완료. 게임 실행 버튼을 누르면 경기 시작 시 자동 녹화를 시도합니다.'='Replay mod installed. Launch the game to record when a match starts.'
 '모드를 백업 폴더로 이동해 비활성화했습니다.'='Replay mod disabled and moved to a backup folder.'
 '게임을 완전히 종료한 다음 모드를 설치하세요.'='Close the game completely before installing the mod.'
 '이미 설치되어 있습니다. 기존 브리지 제거 후 다시 설치하세요.'='Already installed. Remove the replay mod before reinstalling.'
 '리플레이를 불러옵니다. 검증 범위: 오프라인 스커미시 / 관전자 HUD·본진·건설 장면.'='Loading replay. Tested scope: offline skirmish, spectator HUD, bases and construction.'
 '리플레이를 먼저 실행하세요. 게임에서는 1·2·4키로 배속을 선택할 수 있습니다.'='Start a replay first. Use 1, 2 or 4 in game to select playback speed.'
 '지원하지 않는 배속입니다.'='Unsupported speed.';'브리지 응답 없음. 진단 로그를 확인하세요. 녹화되지 않았을 수 있습니다.'='No bridge response. Check logs; recording may not have started.'
 '녹화 미시작 · 경기 시작 판정 대기'='Waiting for match start';'이 경기 녹화 안 됨 · 시작 판정 확인 필요'='Match was not recorded; check match detection'
 '녹화 명령 전송 · 성공 확인 중'='Recording requested; checking result';'기록 드라이버 활성 · 파일 확인 필요'='Recording driver active; checking file'
 '녹화 실패 · 기록 드라이버가 생성되지 않음'='Recording failed: no driver';'경기 화면 종료 · 아래 기록 결과 확인'='Match ended; see recording result'
 '브리지 오류'='Bridge error';'관전자 HUD·카메라 연결됨'='Spectator HUD and camera connected';'리플레이 로딩 요청'='Replay loading requested';'리플레이 종료'='Replay finished'
 '유닛 이동 보조 기록 중'='Recording movement companion';'유닛 이동 보조 파일 재생 중'='Playing movement companion';'이동 보조 파일 없음 · 기본 재생'='No companion; native playback'
 '유닛 이동 보조 기록/재생 오류'='Movement companion error';'보병 모션 보정 오류'='Infantry animation correction error'
 '기록 파일 이름 확인 필요'='Check recording filename';'기록 파일 없음 · 녹화 성공 아님'='No replay file; recording not confirmed';'빈 기록 파일 · 녹화 성공 아님'='Empty replay file; recording failed'
 '저장 파일 확인:'='File found:';'(재생 검증 필요)'='(playback verification required)';'브리지:'='Bridge:';'유닛 이동'='Movement';'기록 완료'='Recording complete';'기록'='Recording';'재생 속도'='Playback speed'
 '적용 요청 · 게임 응답은 브리지 상태에서 확인하세요.'='requested; check bridge status for the game response.';'최신 버전입니다.'='The launcher is up to date.'
}
function Get-LocalizedText([string]$Text) {
 if($settings.language -ne 'en'){return $Text}
 if($script:english.ContainsKey($Text)){return $script:english[$Text]}
 foreach($key in @($script:english.Keys | Sort-Object Length -Descending)){$Text=$Text.Replace($key,$script:english[$key])}
 return $Text
}
$script:captions=@{}
foreach($key in $ui.Keys){
 $control=$ui[$key]
 if($control -is [Windows.Controls.Button]){$script:captions[$key]=@('Content',[string]$control.Content)}
 elseif($key -in @('GameLabel','ReplayLabel','LibraryLabel','AutoHint','LimitHint','SpeedLabel')){$script:captions[$key]=@('Text',[string]$control.Text)}
}
function Set-LauncherLanguage {
 foreach($key in $script:captions.Keys){$entry=$script:captions[$key];$ui[$key].($entry[0])=Get-LocalizedText $entry[1]}
 $headers=@('파일','수정 시간','바이트');for($i=0;$i -lt 3;$i++){$ui.ReplayList.View.Columns[$i].Header=Get-LocalizedText $headers[$i]}
}
$ui.Language.SelectedIndex=if($settings.language -eq 'en'){1}else{0}
Set-LauncherLanguage
$ui.Language.Add_SelectionChanged({
 $settings.language=[string]$ui.Language.SelectedItem.Tag
 $settings | ConvertTo-Json | Set-Content $configFile -Encoding UTF8
 Set-LauncherLanguage
 $ui.Status.Text=(Get-LocalizedText '');$ui.BridgeStatus.Text=(Get-LocalizedText '');$ui.MovementStatus.Text=(Get-LocalizedText '')
})
$ui.Help.Add_Click({
 $help=if($settings.language -eq 'en'){@'
Replay controls
Mouse at screen edge: move camera. Click minimap: move camera.
Select a unit, then C: toggle tracking. F6: cycle starting bases.
U: toggle spectator HUD. I: toggle resource statistics.
Q / W / E / R / T / Y / A / S: select statistics in dropdown order.
1 / 2 / 4: select 1x / 2x / 4x. F7: cycle speeds. F8: pause/resume.
Exit: game menu > Main menu > Confirm (closes the replay process).

Shortcuts and speed apply only during replay playback.
Only data received by your client is recorded; unseen enemy movement may be missing.
Seeking is unsupported. Launcher language does not change the game's language.
'@}else{@'
리플레이 조작키
마우스를 화면 가장자리로 이동: 카메라 이동 / 미니맵 클릭: 해당 위치로 이동
유닛 선택 후 C: 카메라 추적 켜기·끄기 / F6: 본진 순환
U: 관전자 HUD 숨기기·표시 / I: 자원 통계 숨기기·표시
Q / W / E / R / T / Y / A / S: 상세 통계 드롭다운 순서대로 전환
1 / 2 / 4: 1배 / 2배 / 4배속 / F7: 배속 순환 / F8: 일시정지·재개
종료: 게임 메뉴 > 메인 메뉴 > 확인 (리플레이 게임 프로세스 종료)

단축키와 배속은 리플레이 재생 중에만 적용됩니다.
내 클라이언트가 수신한 정보만 기록하므로 시야 밖 적 이동은 누락될 수 있습니다.
시간 탐색은 지원하지 않습니다. 런처 언어는 게임 언어를 바꾸지 않습니다.
'@}
 [Windows.MessageBox]::Show($window,$help,(Get-LocalizedText '조작키 설명')) | Out-Null
})
$ui.Version.Text = "Replay Launcher v$version"
$ui.GamePath.Text = $settings.game
$ui.ReplayPath.Text = $settings.replays
function Show-Error($e) { $ui.Status.Text = Get-LocalizedText $e.Exception.Message }
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
 $ui.Status.Text = (Get-LocalizedText $(if($settings.language -eq 'en'){"$($ui.ReplayList.Items.Count) replays · refreshes every 2 seconds."}else{"리플레이 $($ui.ReplayList.Items.Count)개 · 목록은 2초마다 자동 갱신됩니다."}))
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
 $ui.BridgeStatus.Text=(Get-LocalizedText '게임 브리지 응답 대기 중… 아직 녹화되지 않았습니다.')
}
$ui.Launch.Add_Click({ try { Save-Paths; if (-not (Test-Path -LiteralPath (Join-Path $settings.game 'Tempest.exe'))) { throw 'Tempest.exe를 찾을 수 없습니다.' }; Begin-Bridge 'record'; $ui.Status.Text = (Get-LocalizedText 'Steam에 게임 실행을 요청했습니다.') } catch { Show-Error $_ } })
$ui.InstallBridge.Add_Click({ try { Save-Paths; $ui.InstallBridge.IsEnabled=$false; Install-ReplayBridge $settings.game; $ui.Status.Text=(Get-LocalizedText '녹화·재생 모드 설치 완료. 게임 실행 버튼을 누르면 경기 시작 시 자동 녹화를 시도합니다.') } catch { Show-Error $_ } finally { $ui.InstallBridge.IsEnabled=$true } })
$ui.RemoveBridge.Add_Click({ try { Save-Paths; Remove-ReplayBridge $settings.game; $ui.Status.Text=(Get-LocalizedText '모드를 백업 폴더로 이동해 비활성화했습니다.') } catch { Show-Error $_ } })
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
  $ui.MovementStatus.Text=(Get-LocalizedText '')
  if ($movement.Count -ge 5 -and $movement[0] -eq $script:bridgeSession -and $movement[2] -in @('recording','playing','completed')) {
   $action=if ($movement[2] -eq 'recording') {'기록'} elseif ($movement[2] -eq 'completed') {'기록 완료'} else {'재생'}
   $ui.MovementStatus.Text=(Get-LocalizedText "유닛 이동 $action · $($movement[3]) · $($movement[4]) · $($movement[1]).movement")
  }
  $statusFile=Join-Path $p.Data 'status.txt'
  $lines=@(if (Test-Path $statusFile) { Get-Content $statusFile -Encoding UTF8 })
  if ($lines.Count -ge 4 -and $lines[0] -eq $script:bridgeSession) {
   $labels=@{viewer_safety_error='리플레이 안전 검사 실패 · 게임 빌드와 진단 로그 확인 필요';record_waiting='녹화 미시작 · 경기 시작 판정 대기';record_not_started='이 경기 녹화 안 됨 · 시작 판정 확인 필요';record_requested='녹화 명령 전송 · 성공 확인 중';record_driver_active='기록 드라이버 활성 · 파일 확인 필요';record_failed='녹화 실패 · 기록 드라이버가 생성되지 않음';record_session_left='경기 화면 종료 · 아래 기록 결과 확인';bridge_error='브리지 오류';probe_ready='진단 준비 완료';viewer_initializing='관전자 HUD·카메라 연결됨';play_requested='리플레이 로딩 요청';viewer_finished='리플레이 종료';animation_error='보병 모션 보정 오류';movement_recording='유닛 이동 보조 기록 중';movement_playback='유닛 이동 보조 파일 재생 중';movement_missing='이동 보조 파일 없음 · 기본 재생';movement_error='유닛 이동 보조 기록/재생 오류'}
   $label=if ($labels.ContainsKey($lines[2])) { $labels[$lines[2]] } else { $lines[2] }
   $ui.BridgeStatus.Text=(Get-LocalizedText "브리지: $label · $($lines[3])")
   if ($lines[2] -in @('record_requested','record_driver_active','record_session_left')) {
    $ui.BridgeStatus.Text += ' · '+(Get-RecordingFileMessage $lines[3])
    if ($lines[2] -eq 'record_session_left') { Sync-ReplayLibrary $true }
   }
  } elseif (((Get-Date)-$script:bridgeStarted).TotalSeconds -gt 120) { $ui.BridgeStatus.Text=(Get-LocalizedText '브리지 응답 없음. 진단 로그를 확인하세요. 녹화되지 않았을 수 있습니다.') }
 } catch { $ui.BridgeStatus.Text=Get-LocalizedText $_.Exception.Message }
})
$timer.Start()
$window.Add_Closed({ $timer.Stop() })
function Import-ReplayFiles([string]$Source,[string]$Folder) {
 if ([IO.Path]::GetExtension($Source) -ieq '.zip') { return Import-ReplayPackage $Source $Folder }
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
function Export-ReplayPackage([string]$Source,[string]$Destination) {
 Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
 $companion=[IO.Path]::ChangeExtension($Source,'.movement')
 if (-not (Test-Path -LiteralPath $companion -PathType Leaf)) { throw '이동 보조 파일이 없어 묶음을 만들 수 없습니다.' }
 $streams=@();$zip=$null;$output=$null;$created=$false
 try {
  # Deny writers while reading either part, so an active recording cannot be exported halfway.
  foreach($path in @($Source,$companion)) { $streams+=,[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read) }
  if ($streams[0].Length -eq 0 -or $streams[1].Length -eq 0) { throw '빈 기록 파일은 공유할 수 없습니다.' }
  $output=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$created=$true
  $zip=New-Object IO.Compression.ZipArchive($output,[IO.Compression.ZipArchiveMode]::Create,$true)
  $paths=@($Source,$companion)
  for($i=0;$i -lt 2;$i++) {
   $entry=$zip.CreateEntry([IO.Path]::GetFileName($paths[$i]),[IO.Compression.CompressionLevel]::Optimal)
   $target=$entry.Open();try {$streams[$i].CopyTo($target)} finally {$target.Dispose()}
  }
  $zip.Dispose();$zip=$null;$output.Dispose();$output=$null
 } catch {
  if($zip){$zip.Dispose();$zip=$null};if($output){$output.Dispose();$output=$null}
  if($created){[IO.File]::Delete($Destination)}
  throw
 } finally {if($zip){$zip.Dispose()};if($output){$output.Dispose()};foreach($stream in $streams){$stream.Dispose()}}
 return $Destination
}
function Import-ReplayPackage([string]$Source,[string]$Folder) {
 Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
 $zip=[IO.Compression.ZipFile]::OpenRead($Source);$stage=$null
 try {
  $entries=@($zip.Entries)
  if($entries.Count -ne 2){throw '같은 이름의 replay와 movement 두 파일만 들어 있는 ZIP을 선택하세요.'}
  foreach($entry in $entries) {
   if($entry.FullName -notmatch '^[a-zA-Z0-9_-]+\.(replay|movement)$' -or $entry.Length -le 0 -or $entry.Length -gt 8GB){throw '지원하지 않는 리플레이 묶음입니다.'}
  }
  $replay=@($entries | Where-Object {$_.FullName -match '\.replay$'})
  $movement=@($entries | Where-Object {$_.FullName -match '\.movement$'})
  if($replay.Count -ne 1 -or $movement.Count -ne 1 -or [IO.Path]::GetFileNameWithoutExtension($replay[0].FullName) -cne [IO.Path]::GetFileNameWithoutExtension($movement[0].FullName)){throw '지원하지 않는 리플레이 묶음입니다.'}
  foreach($entry in $entries){if(Test-Path -LiteralPath (Join-Path $Folder $entry.FullName)){throw '같은 이름의 리플레이 또는 이동 파일이 이미 있습니다. 원본을 유지합니다.'}}
  $stage=Join-Path ([IO.Path]::GetTempPath()) ('TempestImport-'+[guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($stage) | Out-Null
  foreach($entry in $entries){[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $stage $entry.FullName),$false)}
  return Import-ReplayFiles (Join-Path $stage $replay[0].FullName) $Folder
 } finally {
  $zip.Dispose()
  if($stage){foreach($file in [IO.Directory]::GetFiles($stage)){[IO.File]::Delete($file)};[IO.Directory]::Delete($stage)}
 }
}
$ui.Export.Add_Click({
 try {
  if(Get-Process -Name 'Tempest*' -ErrorAction SilentlyContinue){throw '게임을 먼저 종료하세요.'}
  $replay=$ui.ReplayList.SelectedItem
  if(-not $replay){throw '재생할 파일을 선택하세요.'}
  $dialog=New-Object Windows.Forms.SaveFileDialog
  $dialog.Filter='Replay package (*.zip)|*.zip';$dialog.FileName=[IO.Path]::GetFileNameWithoutExtension($replay.Name)+'.zip'
  try {
   if($dialog.ShowDialog() -eq 'OK') {
    Export-ReplayPackage $replay.FullName $dialog.FileName | Out-Null
    $ui.Status.Text=(Get-LocalizedText '공유용 ZIP 저장 완료: ')+$dialog.FileName
   }
  } finally {$dialog.Dispose()}
 } catch {Show-Error $_}
})
$ui.Import.Add_Click({
 try {
  Save-Paths; $dialog = New-Object Windows.Forms.OpenFileDialog; $dialog.Filter = 'Replay / package (*.replay;*.zip)|*.replay;*.zip'
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
  $ui.Status.Text = (Get-LocalizedText '리플레이를 불러옵니다. 검증 범위: 오프라인 스커미시 / 관전자 HUD·본진·건설 장면.')
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
  if (-not $script:bridgeSession -or $script:bridgeMode -ne 'play') { throw '리플레이를 먼저 실행하세요. 게임에서는 1·2·4키로 배속을 선택할 수 있습니다.' }
  $speed=[string]$ui.PlaybackSpeed.SelectedItem.Tag
  if ($speed -notin @('0.5','1','2','4')) { throw '지원하지 않는 배속입니다.' }
  $p=Get-BridgePaths $settings.game
  [IO.File]::WriteAllText((Join-Path $p.Data 'control.tmp'),"$script:bridgeSession`nspeed=$speed`n")
  Move-Item -LiteralPath (Join-Path $p.Data 'control.tmp') -Destination (Join-Path $p.Data 'control.txt') -Force
  $ui.Status.Text=(Get-LocalizedText "재생 속도 $($speed)x 적용 요청 · 게임 응답은 브리지 상태에서 확인하세요.")
 } catch { Show-Error $_ }
})
$script:updateProcess=$null
$script:updateStatusFile=$null
$updateTimer=New-Object Windows.Threading.DispatcherTimer
$updateTimer.Interval=[TimeSpan]::FromMilliseconds(500)
$updateTimer.Add_Tick({
 try {
  if(Test-Path -LiteralPath $script:updateStatusFile){
   $progress=Get-Content -LiteralPath $script:updateStatusFile -Raw | ConvertFrom-Json
   $ui.Status.Text=Get-LocalizedText $progress.message
   $ui.Update.Content=Get-LocalizedText $progress.message
   if($progress.state -eq 'ready'){$updateTimer.Stop();$window.Close();return}
   if($progress.state -in @('current','error')){
    $updateTimer.Stop();$ui.Update.IsEnabled=$true;$ui.Update.Content=(Get-LocalizedText '런처 업데이트')
    [Windows.MessageBox]::Show($window,(Get-LocalizedText $progress.message),(Get-LocalizedText '런처 업데이트')) | Out-Null
    return
   }
  }
  if($script:updateProcess.HasExited){throw "업데이트 작업이 중단되었습니다. 로그: $script:updateStatusFile.log"}
 } catch {
  $updateTimer.Stop();$ui.Update.IsEnabled=$true;$ui.Update.Content=(Get-LocalizedText '런처 업데이트')
  $ui.Status.Text=Get-LocalizedText $_.Exception.Message
  [Windows.MessageBox]::Show($window,(Get-LocalizedText $_.Exception.Message),(Get-LocalizedText '런처 업데이트 오류')) | Out-Null
 }
})
$ui.Update.Add_Click({
 try {
  $ui.Update.IsEnabled=$false;$ui.Update.Content=(Get-LocalizedText '최신 버전 확인 중…');$ui.Status.Text=(Get-LocalizedText '업데이트를 확인합니다…')
  $requestFolder=Join-Path $data ('updates\'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $requestFolder -Force | Out-Null
  $script:updateStatusFile=Join-Path $requestFolder 'status.json'
  # A separate process keeps all network and archive work off the WPF UI thread.
  $worker=Join-Path $root 'Update.ps1'
  $script:updateProcess=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$worker+'"'),'-Check','-Target',('"'+$root+'"'),'-CurrentVersion',$version,'-StatusPath',('"'+$script:updateStatusFile+'"'),'-WaitPid',$PID)
  $updateTimer.Start()
 } catch {
  $ui.Update.IsEnabled=$true;$ui.Update.Content=(Get-LocalizedText '런처 업데이트');Show-Error $_
  [Windows.MessageBox]::Show($window,(Get-LocalizedText $_.Exception.Message),(Get-LocalizedText '런처 업데이트 오류')) | Out-Null
 }
})
try { Refresh-Replays } catch { Show-Error $_ }
$window.ShowDialog() | Out-Null
