# JaeYun XeFG6x r2 빌드 기록

재윤님의 기존 FSR 업스케일링과 Intel 프레임 생성 조합을 보존하기 위한 OptiScaler 코어 빌드입니다.
이 CI 산출물은 완전한 설치 패키지가 아닙니다. 최종 MO2 패키지는 제공된 기존 파일의 AMD·Intel 런타임과 설정을 유지하여 별도로 조립합니다.

## 소스와 재현

- 기반: `Coldwood1026/OptiScalerDp4aUnlock` 커밋 `9eea95bba9fda7121f214d2eba358423be598d7e`.
- 검토한 추가 변경: `jaeyun.patch`. 정확한 패치와 변경 전후 소스 해시는 `SOURCE.json`에 기록합니다.
- 소스 해시는 CRLF를 LF로 정규화한 바이트 기준입니다. 패치 자체 해시는 파일의 실제 바이트 기준입니다.
- Windows Server 2022 / VS2022 v143의 `Release|x64`로 빌드합니다. 재귀 submodule checkout이 필요합니다.
- `prepare.py`는 원본 커밋과 해시를 확인한 뒤 패치를 적용하고, 기존 Release 최적화와 NDEBUG를 유지하면서 PDB 생성을 켭니다.
- 버전 문자열에는 `JaeYun-XeFG6x-r2-<빌더 커밋>`을 기록합니다. upstream의 빌드 날짜 생성 단계가 이 식별자를 덮어쓰지 않습니다.
- `check_prepared.py`는 준비한 파일·컴파일 설정을 다시 확인합니다. `tests/run.py`는 별도의 변경 관련 회귀 테스트를 실행합니다.
- `package.py`는 AMD64 PE DLL, 실제 DXGI export table, 버전 식별자, DLL과 PDB의 GUID/age 일치를 확인합니다.

## 산출물

- `core/OptiScaler.dll`: 최종 패키지에 넣을 코어입니다. 최종 설치 파일명과 경로는 기존 구성에 맞춥니다.
- `symbols/OptiScaler.pdb`: 해당 DLL과 일치하는 진단 심볼입니다. 게임 설치에 필요하지 않습니다.
- `BUILD.json`, `TEST_RESULTS.json`: 컴파일·회귀 검증·파일 해시 기록입니다.
- `SOURCE_EVIDENCE.zip`: 소스 잠금, 패치, 빌드 도구, 준비된 수정 파일, 테스트 기록입니다. 전체 원본 소스와 의존성은 위 고정 커밋에서 재귀 checkout할 수 있습니다.
- `LICENSE_OptiScaler.txt`: GPL 라이선스입니다. 원본 프로젝트 및 Coldwood 기여자의 저작권과 라이선스를 유지합니다.

이 산출물에는 DLSS5/NR 엔진·모델·Matheus NR 애드온을 추가하지 않습니다. 일반 OptiScaler의 DLSS 입력 호환 코드는 Intel FG와의 연결에 사용될 수 있습니다.
Windows 빌드와 회귀 테스트 통과는 실제 RX 9070 XT의 화질·FPS·장시간 안정성 검증을 대신하지 않습니다.

## R2 수정 범위

- 게임에 보고하는 최대 배수를 INI의 최대 보간 수와 일치시킵니다. 전달 패키지는 최대6배, 초기 선택3배입니다.
- 프레임 시간 입력의 기존 우선순위를 복원하고, FG 중단·재개 때 표시 간격 계산의 이전 측정값을 무효화합니다.
- 유예 중 화면 이력 초기화 요청을 보관하여 성공한 프레임 상수 전달에서 한 번 처리합니다.
- 자동 움직임·깊이 설정에는 유효한 입력만 적용하며 일시적 자동 학습을 INI에 저장하지 않습니다.
- FFX 필수 자원 입력을 먼저 검증하고 유효하지 않은 노출값과 crop 자원 상태 복원을 보완합니다.

맵 복귀·FPS·피부색·잔상 개선은 실제 게임에서 확인해야 합니다. 코드 검증과 컴파일 성공만으로 이 증상들이 해결되었다고 판단하지 않습니다.
