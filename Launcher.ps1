$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$data = Join-Path $env:LOCALAPPDATA 'TempestReplayLauncher'
New-Item $data -ItemType Directory -Force | Out-Null
$configFile = Join-Path $data 'settings.json'
$settings = @{ game = 'C:\Program Files (x86)\Steam\steamapps\common\Tempest Rising'; replays = (Join-Path $env:LOCALAPPDATA 'Tempest\Saved\Demos') }
if (Test-Path $configFile) { try { $c = Get-Content $configFile -Raw | ConvertFrom-Json; $settings.game = $c.game; $settings.replays = $c.replays } catch {} }
$version = (Get-Content (Join-Path $root 'version.json') -Raw | ConvertFrom-Json).version
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="TEMPEST · Replay Launcher" Width="900" Height="680" MinWidth="760" MinHeight="620" Background="#101820" Foreground="#E6EDF3" WindowStartupLocation="CenterScreen">
 <Window.Resources><Style TargetType="Button"><Setter Property="Margin" Value="4"/><Setter Property="Padding" Value="14,9"/><Setter Property="Background" Value="#B9E873"/><Setter Property="Foreground" Value="#101820"/></Style><Style TargetType="TextBox"><Setter Property="Margin" Value="4"/><Setter Property="Padding" Value="8"/></Style></Window.Resources>
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <DockPanel><Button Name="Update" DockPanel.Dock="Right" Content="런처 업데이트"/><StackPanel><TextBlock Text="TEMPEST" FontSize="30" FontWeight="Bold" Foreground="#B9E873"/><TextBlock Name="Version"/></StackPanel></DockPanel>
 <StackPanel Grid.Row="1" Margin="0,18,0,8"><TextBlock Text="게임 설치 폴더"/><DockPanel><Button Name="BrowseGame" DockPanel.Dock="Right" Content="찾기"/><TextBox Name="GamePath"/></DockPanel><TextBlock Text="리플레이 폴더"/><DockPanel><Button Name="BrowseReplay" DockPanel.Dock="Right" Content="찾기"/><TextBox Name="ReplayPath"/></DockPanel></StackPanel>
 <TextBlock Grid.Row="2" Text="리플레이 라이브러리 · .replay" FontSize="18" Margin="4,6"/>
 <ListView Grid.Row="3" Name="ReplayList" Background="#1B2935" Foreground="White" Margin="4"><ListView.View><GridView><GridViewColumn Header="파일" DisplayMemberBinding="{Binding Name}" Width="380"/><GridViewColumn Header="수정 시간" DisplayMemberBinding="{Binding LastWriteTime}" Width="200"/><GridViewColumn Header="바이트" DisplayMemberBinding="{Binding Length}" Width="100"/></GridView></ListView.View></ListView>
 <StackPanel Grid.Row="4"><WrapPanel><Button Name="Launch" Content="Steam 게임 실행"/><Button Name="Refresh" Content="새로고침 / 경로 저장"/><Button Name="Import" Content="리플레이 가져오기"/><Button Name="Open" Content="폴더 열기"/></WrapPanel><CheckBox Name="Experimental" Margin="5,10" Content="미검증 Unreal 재생 명령 사용에 동의 (게임 지원 필요)"/><Button Name="Play" Content="선택 리플레이 실험적 재생" IsEnabled="False" HorizontalAlignment="Left"/><TextBlock Text="관전자 UI: 게임 내부 구현 필요 · 녹화/재생 및 관전자 전환은 현재 검증되지 않았습니다." TextWrapping="Wrap" Margin="4,8" Foreground="#FFC778"/></StackPanel>
 <TextBlock Grid.Row="5" Name="Status" TextWrapping="Wrap" Margin="4,12,4,0" Foreground="#A8B7C5"/>
 </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
@('Update','Version','GamePath','ReplayPath','BrowseGame','BrowseReplay','ReplayList','Launch','Refresh','Import','Open','Experimental','Play','Status') | ForEach-Object { $ui[$_] = $window.FindName($_) }
$ui.Version.Text = "Replay Launcher v$version"
$ui.GamePath.Text = $settings.game
$ui.ReplayPath.Text = $settings.replays
function Show-Error($e) { $ui.Status.Text = $e.Exception.Message }
function Save-Paths {
 if (-not [IO.Path]::IsPathRooted($ui.GamePath.Text) -or -not [IO.Path]::IsPathRooted($ui.ReplayPath.Text)) { throw '절대 경로를 입력하세요.' }
 $settings.game = $ui.GamePath.Text; $settings.replays = $ui.ReplayPath.Text
 $settings | ConvertTo-Json | Set-Content $configFile -Encoding UTF8
}
function Refresh-Replays {
 Save-Paths
 $ui.ReplayList.ItemsSource = @(if (Test-Path -LiteralPath $settings.replays) { Get-ChildItem -LiteralPath $settings.replays -Filter '*.replay' -File | Sort-Object LastWriteTime -Descending })
 $ui.Status.Text = "리플레이 $($ui.ReplayList.Items.Count)개 · 실제 게임 리플레이 데이터가 필요합니다."
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
$ui.Launch.Add_Click({ try { Save-Paths; if (-not (Test-Path -LiteralPath (Join-Path $settings.game 'Tempest.exe'))) { throw 'Tempest.exe를 찾을 수 없습니다.' }; Start-Process 'steam://rungameid/1486920'; $ui.Status.Text = 'Steam에 게임 실행을 요청했습니다.' } catch { Show-Error $_ } })
$ui.Import.Add_Click({
 try {
  Save-Paths; $dialog = New-Object Windows.Forms.OpenFileDialog; $dialog.Filter = 'Unreal replay (*.replay)|*.replay'
  if ($dialog.ShowDialog() -eq 'OK') {
   New-Item -ItemType Directory -Path $settings.replays -Force | Out-Null
   $destination = Join-Path $settings.replays ([IO.Path]::GetFileName($dialog.FileName))
   if (Test-Path -LiteralPath $destination) { throw '같은 이름의 파일이 이미 있습니다. 원본을 유지합니다.' }
   Copy-Item -LiteralPath $dialog.FileName -Destination $destination; Refresh-Replays
  }; $dialog.Dispose()
 } catch { Show-Error $_ }
})
$ui.Experimental.Add_Click({ $ui.Play.IsEnabled = [bool]$ui.Experimental.IsChecked })
$ui.Play.Add_Click({
 try {
  Save-Paths; $replay = $ui.ReplayList.SelectedItem
  if (-not $replay) { throw '재생할 파일을 선택하세요.' }
  $name = [IO.Path]::GetFileNameWithoutExtension($replay.Name)
  if ($name -notmatch '^[a-zA-Z0-9_-]+$') { throw '실험적 재생 파일명은 영문, 숫자, 밑줄, 하이픈만 사용할 수 있습니다.' }
  $default = Join-Path $env:LOCALAPPDATA 'Tempest\Saved\Demos'
  if ([IO.Path]::GetFullPath($settings.replays).TrimEnd('\') -ne [IO.Path]::GetFullPath($default)) { throw '실험적 재생에는 기본 폴더 %LOCALAPPDATA%\Tempest\Saved\Demos를 사용하세요.' }
  if (Get-Process -Name 'Tempest-Win64-Shipping','Tempest' -ErrorAction SilentlyContinue) { throw '게임을 먼저 종료하세요.' }
  if (-not (Test-Path -LiteralPath (Join-Path $settings.game 'Tempest.exe'))) { throw '게임 경로를 확인하세요.' }
  Start-Process "steam://run/1486920//-ExecCmds%3D%22demoplay%20$name%22/"
  $ui.Status.Text = 'demoplay 요청을 Steam에 전달했습니다. 성공 여부와 관전자 UI는 게임 내에서 확인해야 합니다.'
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
  foreach ($file in @('Launcher.ps1','Start.cmd','version.json')) { if (-not (Test-Path (Join-Path $stage "files\$file"))) { throw "배포 파일 누락: $file" } }
  if ([version](Get-Content (Join-Path $stage 'files\version.json') -Raw | ConvertFrom-Json).version -ne $latest) { throw '릴리스 버전과 배포 버전이 다릅니다.' }
  Copy-Item (Join-Path $root 'Update.ps1') (Join-Path $stage 'Update.ps1')
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $stage 'Update.ps1')+'"'),'-Target',('"'+$root+'"'),'-Source',('"'+(Join-Path $stage 'files')+'"'),'-WaitPid',$PID)
  $window.Close()
 } catch { $ui.Status.Text = "업데이트 확인 실패: $($_.Exception.Message) (아직 릴리스가 없거나 네트워크 오류일 수 있습니다.)" }
 finally { $ui.Update.IsEnabled = $true }
})
try { Refresh-Replays } catch { Show-Error $_ }
$window.ShowDialog() | Out-Null
