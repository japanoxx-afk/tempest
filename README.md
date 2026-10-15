# tempest

Tempest Rising용 Windows 리플레이 런처 초기 버전입니다. `Start.cmd`를 더블클릭하세요. Windows PowerShell 5.1과 Steam이 필요합니다. 관리자 권한은 필요하지 않습니다.

## 현재 제공 기능

- 지정된 설치 경로 확인 및 Steam 게임 실행
- `.replay` 파일 목록, 가져오기, 폴더 열기
- 명시적으로 활성화하는 실험적 Unreal `demoplay` 실행 요청
- UE4SS 실험 모드 설치/백업 제거, 런처 실행 세션별 경기 자동 기록 요청
- 호환성 진단과 관전자 컨트롤러/HUD 연결 시도 (실게임 검증 전)
- GitHub Releases 최신 버전 확인, SHA256 검증, 업데이트 설치 및 재시작
- 설정은 `%LOCALAPPDATA%\TempestReplayLauncher`에 저장

## 리플레이 및 관전자 UI 상태

**실제 경기 녹화, 리플레이 재생, 리플레이 관전자 UI는 구현/검증 완료 상태가 아닙니다.** 이 런처는 게임에 없는 리플레이 데이터를 생성하지 않습니다. Unreal 엔진으로 제작됐다는 사실만으로 shipping 빌드의 `demoplay` 지원이 보장되지 않습니다. 실험적 재생은 기본 `Tempest\Saved\Demos` 폴더의 기존 `.replay` 파일에 명령을 전달할 뿐입니다. Steam 실행 인수 전달 및 게임 명령 처리도 실게임 검증이 필요합니다.

게임 내부의 DemoNetDriver, 녹화 대상 복제, ReplaySpectatorPlayerController와 관전자 HUD 연결이 필요합니다. 공식 모딩 SDK/소스 또는 지원되는 플러그인 인터페이스를 확보한 후 게임 통합 구현이 필요합니다. 게임 바이너리, 암호화 키, Steam 파일을 변경하거나 업로드하지 않습니다.

## 개발 중인 게임 내부 연동

현재 소스에는 실험 브리지가 추가되어 있습니다. 아직 실게임 테스트를 통과하지 않았고, v0.1.0 배포에는 포함되어 있지 않습니다. 새 소스로 실행한 뒤 게임을 종료하고 `실험 모드 설치` → `호환성 진단 실행` 순서로 확인합니다. UE4SS는 비공식 로더이며 이 게임에서의 호환성은 미검증입니다. 먼저 오프라인 스커미시에서 테스트해야 합니다.

진단 후 게임을 종료하고 `게임 실행 시 경기 자동 기록 시도`를 체크한 상태로 실행하면 브리지가 경기 시작을 기다린 뒤 기록 명령을 보냅니다. 명령 전송이 녹화 성공을 의미하지는 않습니다. 생성 파일과 실제 재생을 확인해야 합니다. 선택 리플레이 재생도 관전자 클래스와 HUD 연결을 시도하는 단계이며, 동작을 보장하지 않습니다. 일반 Steam 실행에서는 새 런처 요청이 없으면 브리지 코드가 동작하지 않지만 로더 DLL 자체는 로드됩니다. `실험 모드 제거`로 로더와 모드를 백업 폴더로 옮길 수 있습니다.

조사 근거와 남은 검증 항목은 [조사 기록](docs/REPLAY-INVESTIGATION.md)에 있습니다. 모의 UE4SS 호스트에서 14개 제어 흐름 테스트를 통과했으며 이는 실제 게임 호환성 검증을 대체하지 않습니다.

현재 소스는 다음 게임 실행 전에 설치된 브리지 Lua를 자동 동기화합니다. v0.2.3은 잘못된 CallFunction 호출을 제거하고, 실제 실행 중인 엔진의 드라이버 목록에 누락된 DemoNetDriver만 추가합니다. 기존 GameNetDriver와 BeaconNetDriver는 유지합니다. 이전 버전이 추가한 사용자 Engine.ini 블록은 모드 제거 시 정리하며 새 버전은 해당 블록을 추가하지 않습니다. 명령 요청은 진단 폴더의 `commands.log`, 세션 이력은 `events.log`, 실제 드라이버 설정은 `net-drivers.txt`에 남습니다. 명령 경로는 성공 응답을 제공하지 않으며 기록 드라이버가 생성되지 않으면 런처에 녹화 실패를 표시합니다. 과거에 저장되지 않은 경기의 리플레이를 복원하는 기능은 없습니다.

공식 관전자 모드는 게임의 멀티플레이 사용자 지정 로비에서 선택할 수 있습니다. 이것이 과거 경기 리플레이 지원을 의미하지는 않습니다.

- [Unreal Replay System](https://dev.epicgames.com/documentation/unreal-engine/using-the-replay-system-in-unreal-engine)
- [DemoNetDriver와 관전자 컨트롤러](https://dev.epicgames.com/documentation/en-us/unreal-engine/demonetdriver-and-streamers-in-unreal-engine)
- [공식 관전자 모드 패치 노트](https://support.saber.games/hc/en/tempest-rising/articles/september-9-2025-patch-notes-13)

## 업데이트 배포

`version.json`의 숫자 버전을 올리고 커밋한 뒤 일치하는 `v0.1.1` 등의 태그를 push하면 GitHub Actions가 ZIP과 SHA256 파일을 Release에 게시합니다. 런처 업데이트 버튼은 이 저장소의 최신 정식 Release를 확인합니다. 첫 릴리스를 게시하기 전에는 업데이트 확인이 실패할 수 있습니다. 체크섬은 전송 무결성을 확인하며 코드 서명을 대체하지 않습니다.

소스 checkout에서 업데이트하면 배포 파일을 덮어쓰므로 개발 중에는 별도 배포 폴더에서 실행하세요.
