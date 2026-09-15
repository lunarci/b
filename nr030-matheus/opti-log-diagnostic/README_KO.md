# OptiScaler 실행 로그 진단 도구

현재 Effect 0에서 XeFG Active를 켜면 흰색 깨짐, 끄면 팔 주변 잔상이 보이는 문제의 실행 로그를 수집합니다. **그래픽 문제를 고치는 패치가 아닙니다.** NR, Effect, 업스케일 비율, XeFG 활성과 배수는 바꾸지 않습니다.

기존 수집기는 OptiScaler.ini에 지정된 `C:\CYBERPUNK_ARK_PACK_MO2\OptiScaler-debug.log`를 놓치고 기본 `OptiScaler.log`를 수집했습니다. 이번 도구는 지정된 경로도 전체 수집하며, 새로운 로그를 기록할 임시 설정과 복구 기능을 제공합니다.

## 실행 순서

압축은 다운로드 폴더 등 쓰기 가능한 곳에 모두 풀어 주세요. 게임 폴더에 덮어쓸 필요가 없습니다. 아래 CMD 파일들이 함께 있는 폴더에서 실행합니다. 대상 MO2 폴더는 기존 `C:\CYBERPUNK_ARK_PACK_MO2`입니다.

1. 게임과 MO2를 완전히 종료하고 **01_ENABLE_LOG.cmd**를 실행합니다.
2. 평소처럼 MO2에서 게임을 시작합니다. 현재 **Effect 0, XeFG Active 켜짐**을 유지하고 팔을 움직여 흰색 깨짐을 15~30초 정도 재현합니다. 이미 확인한 ON/OFF 비교를 반복할 필요는 없습니다.
3. 게임과 MO2를 종료하고 **02_COLLECT_LOGS.cmd**를 실행합니다. 이 도구 폴더의 `Results`에 `MOTION_EVIDENCE-날짜-번호.zip`이 생성됩니다.
4. **03_RESTORE_LOG_SETTINGS.cmd**를 실행해 이전 로그 설정으로 복구합니다. 생성된 증거 ZIP을 대화에 첨부해 주세요.

로그 기록 중에는 디스크 기록 부하가 추가될 수 있으므로 이 실행의 FPS를 성능 비교에 사용하지 마세요. 복구 버튼은 로깅 설정만 복구하며 진단 로그와 증거 ZIP은 보존합니다.

## 변경 범위와 확인 범위

- 존재하는 ARK/overwrite의 OptiScaler.ini에서 `[Log]`의 `LogToFile`, `LogLevel`, `LogFileName` 세 값만 임시 변경합니다.
- 임시 파일 경로는 `C:\CYBERPUNK_ARK_PACK_MO2\Matheus_NR030_Diagnostic\OptiScaler-current.log`입니다.
- 원래 로그 설정은 `Matheus_NR030_OptiLog_Backup`에 별도로 보관합니다. 복구 시 이후 사용자가 바꾼 다른 설정은 유지합니다.
- 이미 로그를 켠 상태에서 01을 다시 실행해도 최초 원래 값은 보존합니다. 로그 설정 자체가 다른 값으로 바뀌면 자동 덮어쓰기를 중단합니다.
- 사용자 현재 설정의 `SingleFile=auto`에 맞춰 정확한 로그 파일명을 수집합니다. `SingleFile=false`의 세션 접미사 파일은 이 수집기의 지원 대상이 아니며 누락 설명을 남깁니다.
- 수집 ZIP의 `inventory.json`에 원래 경로·수정 시각·SHA-256이 들어갑니다. `COLLECTION_NOTES.txt`에는 설정과 누락 이유가 들어갑니다. 파일 시각만으로 최신 실행 여부를 확정하지 않습니다.
- 필요한 원본 0.2.4 파일은 상태 비교용으로 포함되어 있습니다. 이 도구의 세 버튼은 ASI/DLL을 설치하거나 교체하지 않습니다.
- Windows PowerShell 5.1의 설정 변경·복구와 로그 수집 검증은 포함된 출처 기록에 연결됩니다. 사용자 PC의 실제 로깅, GPU 동작, 그래픽 개선은 별도 확인이 필요합니다.

## 현재 확인된 증상 해석

Effect 0으로 피부 자글거림이 사라졌다는 결과는 NR 화면 보정의 기여와 연결됩니다. 그러나 Effect 0에서도 NR 계산과 색상 리소스 교체는 남습니다. XeFG OFF에서 흰색 깨짐이 사라지는 결과는 프레임 생성 경로 또는 앞단 처리와의 상호작용을 조사할 근거이며, XeFG 단독 결함을 확정하지 않습니다. OFF의 잔상은 프레임 빈도 변화와 실제 시간 누적 오류를 아직 구분하지 못했습니다.
