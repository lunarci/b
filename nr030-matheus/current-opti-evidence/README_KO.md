# 현재 OptiScaler 실행 증거 수집

흰색 깨짐이 계속된 최신 실행에서 NR 수정본은 정상 로드됐지만 활성 조건부 실행은 관찰되지 않았습니다. 이번 파일은 **현재 OptiScaler/XeFG 로그와 실제 OptiScaler DLL을 확보하는 수집 도구**입니다. 흰색 깨짐 해결 패치가 아닙니다.

## 실행 순서

1. 게임과 MO2를 종료한 뒤, ZIP 전체를 다운로드 폴더 등 **새 폴더에 압축 해제**합니다.
2. 그 폴더에서 **01_ENABLE_CURRENT_LOG.cmd**를 실행합니다. 기본 대상은 `C:\CYBERPUNK_ARK_PACK_MO2`입니다.
3. 평소처럼 게임을 실행해서 흰색 깨짐을 한 번 재현한 뒤 게임과 MO2를 종료합니다. 장시간 플레이할 필요는 없습니다.
4. **02_COLLECT_CURRENT_EVIDENCE.cmd**를 실행하고, 이 폴더의 `Results`에 새로 생긴 **MOTION_RUNTIME_EVIDENCE-….zip**을 전달합니다.
5. **03_RESTORE_LOG_SETTINGS.cmd**를 실행하면 기록 설정을 이전 값으로 복원합니다. 수집 ZIP은 그대로 남습니다.

대상이 다른 드라이브에 있다면 각 CMD의 첫 인수로 지정합니다. 예: `01_ENABLE_CURRENT_LOG.cmd "D:\My MO2"`.

## 변경 및 수집 범위

01번은 기존 OptiScaler INI의 `[Log]` 아래 `LogToFile`, `LogLevel`, `LogFileName` 세 항목만 변경하고 원래 값을 백업합니다. `LogToFile=true`, `LogLevel=1`로 기록하며 경로는 MO2 폴더 아래 `Matheus_NR030_Diagnostic\OptiScaler-current.log`입니다. 현재 사용 중인 `SingleFile=auto`는 문서상 기본값 true이므로 그대로 둡니다.

NR의 Effect와 입력 85%, 업스케일 비율, XeFG 활성 상태와 4배·5배 선택은 그대로 유지합니다. 실행 파일을 교체하거나 모드를 설치하지 않습니다. 포함된 `payload`는 기존 설치 상태를 확인하는 용도입니다.

02번은 기존 NR·OptiScaler 로그와 설정에 더해 ARK/overwrite 경로에 있는 `dxgi.dll`만 복사합니다. 이 파일이 있어야 실제 사용 중인 OptiScaler 바이너리를 분석할 수 있습니다. 모델 DLL은 수집하지 않습니다. 원본·복사본 해시를 비교하고 파일이 수집 도중 바뀌면 오류로 표시합니다. 수집 파일을 자동 업로드하지 않습니다.

현재 세션 로그가 없거나 오래됐으면 그 사실을 보고서에 표시합니다. 로그 날짜가 최근이라는 사실만으로 실제 XeFG 동작이나 화질 정상 여부를 판정하지 않습니다. 기록을 켠 상태의 성능 수치는 평소 성능과 직접 비교하지 마십시오.

이번 확인기는 `QualityRatioOverrideEnabled=auto`를 문서상 기본값 false로 해석합니다. 따라서 설정이 `OverrideAll=true / Ratio=2.000000 / PerPreset=auto`일 때 잘못된 비율 경고를 출력하지 않습니다. 실제 게임 해상도 검증은 별도입니다.

Windows 검사 결과와 소스 해시는 `evidence`, 수집 도구 소스는 `CONTROL_SOURCE.zip`, 기존 확인용 ASI의 소스는 `baseline/SOURCE.zip`에 포함됩니다.
