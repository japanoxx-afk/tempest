# tempest

Tempest Rising용 Windows 리플레이 런처 초기 버전입니다. `Start.cmd`를 더블클릭하세요. Windows PowerShell 5.1과 Steam이 필요합니다. 관리자 권한은 필요하지 않습니다.

## 현재 제공 기능

- 지정된 설치 경로 확인 및 Steam 게임 실행
- `.replay` 파일 목록, 가져오기, 폴더 열기
- 명시적으로 활성화하는 실험적 Unreal `demoplay` 실행 요청
- GitHub Releases 최신 버전 확인, SHA256 검증, 업데이트 설치 및 재시작
- 설정은 `%LOCALAPPDATA%\TempestReplayLauncher`에 저장

## 리플레이 및 관전자 UI 상태

**실제 경기 녹화, 리플레이 재생, 리플레이 관전자 UI는 구현/검증 완료 상태가 아닙니다.** 이 런처는 게임에 없는 리플레이 데이터를 생성하지 않습니다. Unreal 엔진으로 제작됐다는 사실만으로 shipping 빌드의 `demoplay` 지원이 보장되지 않습니다. 실험적 재생은 기본 `Tempest\Saved\Demos` 폴더의 기존 `.replay` 파일에 명령을 전달할 뿐입니다. Steam 실행 인수 전달 및 게임 명령 처리도 실게임 검증이 필요합니다.

게임 내부의 DemoNetDriver, 녹화 대상 복제, ReplaySpectatorPlayerController와 관전자 HUD 연결이 필요합니다. 공식 모딩 SDK/소스 또는 지원되는 플러그인 인터페이스를 확보한 후 게임 통합 구현이 필요합니다. 게임 바이너리, 암호화 키, Steam 파일을 변경하거나 업로드하지 않습니다.

공식 관전자 모드는 게임의 멀티플레이 사용자 지정 로비에서 선택할 수 있습니다. 이것이 과거 경기 리플레이 지원을 의미하지는 않습니다.

- [Unreal Replay System](https://dev.epicgames.com/documentation/unreal-engine/using-the-replay-system-in-unreal-engine)
- [DemoNetDriver와 관전자 컨트롤러](https://dev.epicgames.com/documentation/en-us/unreal-engine/demonetdriver-and-streamers-in-unreal-engine)
- [공식 관전자 모드 패치 노트](https://support.saber.games/hc/en/tempest-rising/articles/september-9-2025-patch-notes-13)

## 업데이트 배포

`version.json`의 숫자 버전을 올리고 커밋한 뒤 일치하는 `v0.1.1` 등의 태그를 push하면 GitHub Actions가 ZIP과 SHA256 파일을 Release에 게시합니다. 런처 업데이트 버튼은 이 저장소의 최신 정식 Release를 확인합니다. 첫 릴리스를 게시하기 전에는 업데이트 확인이 실패할 수 있습니다. 체크섬은 전송 무결성을 확인하며 코드 서명을 대체하지 않습니다.

소스 checkout에서 업데이트하면 배포 파일을 덮어쓰므로 개발 중에는 별도 배포 폴더에서 실행하세요.
