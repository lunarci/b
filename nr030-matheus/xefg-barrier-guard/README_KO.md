# XeFG 자원 상태 교정본

재윤님의 실제 OptiScaler DLL에서 확인한 자원 상태 복원 결함을 조건부로 교정합니다. 흰색 깨짐의 원인으로 확정된 것은 아니며, 실제로 해당 결함을 차단했는지 로그에 남깁니다.

## 실행 방법

1. 게임과 MO2를 종료하고, ZIP 전체를 다운로드 폴더 등 **새 폴더에 압축 해제**합니다.
2. 그 폴더에서 **01_APPLY_FIX.cmd**를 실행합니다. 기본 대상은 `C:\CYBERPUNK_ARK_PACK_MO2`입니다.
3. 평소처럼 게임을 실행해 같은 장소에서 팔을 움직이며 흰색 깨짐과 잔상을 확인합니다.
4. 게임과 MO2를 종료하고 **03_COLLECT_LOGS.cmd**를 실행합니다. `Results`의 새 **MOTION_RUNTIME_EVIDENCE-….zip**을 전달합니다.
5. 교정본을 되돌리려면 **02_RESTORE_PREVIOUS.cmd**를 실행합니다. 이전 진단판에서 이어진 최초 백업이 있으면 그 백업까지 복원합니다.

다른 MO2 경로를 쓰면 CMD 첫 인수로 지정합니다. 예: `01_APPLY_FIX.cmd "D:\My MO2"`.

## 바뀌는 부분

`MatheusNR030.asi`만 새 빌드로 교체하고 설치 기록을 갱신합니다. 기존 백업을 유지합니다. NR 0.3.0, 모델, OptiScaler, XeFG 바이너리는 교체하지 않습니다. 기존 INI는 유지하므로 입력 85%, Effect 값, 업스케일 비율 2.0, 프레임 생성 4배·5배 선택도 그대로입니다. 포함된 payload INI는 패키지 검증용이며 설치하지 않습니다.

현재 사용 중인 PredicationFix ASI의 정확한 해시도 업그레이드 대상으로 확인합니다. 파일이 다르다는 이유로 검사를 건너뛰거나 임의의 ASI를 덮어쓰지 않습니다.

## 확인된 결함과 교정 조건

확인 대상 OptiScaler SHA-256: `ba4df99acf55278c617780d56b89847553063ebc8e521bf831e09d21d5c0b04b`.

이 DLL은 XeFG 1.2.2 이상에서 이전 버전용 `COPY_SOURCE → COPY_DEST` 우회 처리를 생략하지만, 뒤의 `COPY_DEST → COPY_SOURCE` 복원은 남아 있습니다. 이미 COPY_SOURCE인 자원에 이 복원이 실행되면 앞뒤 상태가 맞지 않습니다. 최신 로그의 XeFG 버전은 1.3.1이지만, 해당 복원 분기 진입 자체는 기존 로그에 없었습니다.

교정본은 파일 해시, 로드된 코드, 자원 상태, 호출 위치와 실행 중인 XeFG 버전을 확인하고 **그 잘못된 복원 호출만 생략**합니다. 이전 XeFG 버전의 정상적인 앞뒤 전환과 다른 호출은 원래 인수 그대로 전달합니다. 새 GPU 버퍼나 GPU 대기는 추가하지 않습니다.

Direct3D 12의 연속 자원 전환은 앞뒤 상태가 일치해야 합니다: [Microsoft 자원 상태 전환 문서](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12).

## 로그 해석과 검증 범위

`MatheusNR030.log`의 `xefg_barrier_guard` 관련 항목이 교정 준비와 실제 차단 횟수를 기록합니다. **차단 횟수가 0이면 해당 결함의 발동을 관찰하지 못한 것입니다.** 준비 완료만으로 흰색 깨짐 해결을 판정하지 않습니다. 처음 관찰한 FFX 명령 목록의 ResourceBarrier 구현을 대상으로 하므로 다른 구현을 사용하는 호출까지 포괄한다고 주장하지 않습니다.

Windows 빌드, 기존 NR 연결·자원 수명 검사, GPU 상태 불일치 대조 실험, WARP 복사·읽기 검사와 설치·복원 검사를 거칩니다. 실제 Radeon 게임에서의 흰색 깨짐 제거와 지연시간은 사용자 실행으로 확인해야 합니다.

`SOURCE.zip`에 소스와 빌드 절차, `evidence`에 검사 결과, `BUILD_PROVENANCE.json`에 소스 커밋과 빌드 주소를 포함합니다.
