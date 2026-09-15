# NR 원본 색상 전달 비교본

재윤님이 확인하신 상태는 NR을 완전히 끄면 흰색 깨짐과 팔 잔상이 모두 사라지고, NR을 켜면 XeFG 활성 여부에 따라 증상이 달라지는 것입니다. XeFG 4배와 5배 모두 깨짐이 나타났으므로, 이 비교본은 의도하신 5배 설정을 유지합니다.

이 파일은 **원인을 좁히기 위한 비교 빌드**입니다. 흰색 깨짐이나 피부 그림자 자글거림이 해결됐다고 검증한 수정본은 아닙니다.

## 바뀌는 처리

현재 `EffectPercent=0`은 NR 계산 뒤 보정량을 화면에 섞지 않는 설정입니다. 기존 추가 모드는 이때에도 원본 색상을 별도 텍스처에 복사해서 FSR에 전달했습니다.

이번 비교본은 **Effect 0에서 그 복사와 텍스처 교체를 생략하고 원래 색상 텍스처를 그대로 FSR에 전달**합니다. NR 계산·85% 입력 축소는 계속 수행합니다. 따라서 NR 완전 끄기와는 다릅니다. 양수 Effect의 기존 합성 코드는 유지했습니다.

설치 도구는 검증된 기존 0.2.4 추가 모드 ASI와 그 설치 기록을 백업하고 비교 ASI로 교체합니다. 존재하는 MO2 overwrite의 동일 ASI도 함께 처리합니다. NR 0.3.0·모델·OptiScaler·XeFG 실행 파일 및 모든 INI 내용은 변경하지 않습니다. `payload/MatheusNR030.ini`는 빌드 파일 해시 검증에만 사용하며 설치하지 않습니다.

재윤님이 얻으신 40→20 지연시간 개선의 기존 설정은 유지합니다. 이 비교본 자체의 지연시간과 화질은 실제 게임에서 측정 전입니다.

## 실행 위치와 순서

다운로드 폴더 등 원하는 곳에 **ZIP 전체를 압축 해제**하십시오. 게임 폴더나 모드 폴더에 직접 덮어쓰지 않습니다. 아래 CMD 파일이 들어 있는 폴더에서 실행합니다. 기본 대상 MO2 폴더는 `C:\CYBERPUNK_ARK_PACK_MO2`입니다.

1. 게임과 MO2를 모두 종료합니다.
2. `01_APPLY_ORIGINAL_COLOR_TEST.cmd`를 실행합니다.
3. 평소처럼 MO2로 게임을 실행합니다. 현재 **Effect 0·NR 입력 85%·XeFG Active 켜짐·의도하신 5배** 상태에서 같은 장면의 팔 움직임을 짧게 비교합니다.
4. 게임과 MO2를 모두 종료한 뒤 `03_COLLECT_LOGS.cmd`를 실행합니다. `Results` 폴더에 생성된 `MOTION_EVIDENCE-….zip`과 흰색 깨짐/팔 잔상의 변화 여부를 전달합니다.
5. 비교가 끝나면 게임·MO2가 종료된 상태에서 `02_RESTORE_PREVIOUS_ADDON.cmd`를 실행하여 직전 추가 모드 ASI와 설치 기록을 복구합니다. 복구 도구는 현재 INI를 바꾸지 않습니다.

기존 추가 모드가 정확한 0.2.4인지, NR이 켜져 있는지, `ScalePercent=85`와 `EffectPercent=0`인지 설치 전에 검사합니다. 맞지 않으면 변경 전에 중단합니다. 설치 과정에서 Effect나 XeFG 배율을 강제로 맞추지 않습니다.

MO2 경로가 다르면 CMD의 첫 번째 인수로 실제 경로를 지정할 수 있습니다. 경로에 공백이 있어도 전체를 따옴표로 묶습니다. 적용·수집·복구 모두 같은 경로를 사용하십시오.

```bat
01_APPLY_ORIGINAL_COLOR_TEST.cmd "D:\My MO2"
03_COLLECT_LOGS.cmd "D:\My MO2"
02_RESTORE_PREVIOUS_ADDON.cmd "D:\My MO2"
```

## 로그를 읽는 방법

새 게임 세션의 `MatheusNR030.log`에서 다음 항목을 확인합니다.

```text
event=effect_zero_handoff diagnostic_build=true mode=original_color_passthrough
event=original_color_stats passthrough=...
```

실제 로그 줄에는 추가 항목이 이어집니다. `passthrough`가 0보다 크면 NR 결과가 준비된 callback에서 원본 색상 전달 분기를 거쳤다는 뜻입니다. 그 자체가 흰색 깨짐 해결이나 NR 추론의 화질을 증명하지는 않습니다.

이 경로에서는 resolve를 생략하므로 기존 통계의 **`resolved=0`이 의도된 상태**입니다. 기존 전체 검사기가 `NO_NR_RESOLVE_RECORDING_OBSERVED`라고 표시할 수 있습니다. 그 문구만으로 이번 비교 경로가 실패했다고 판단하지 마십시오. 새 세션의 passthrough 카운터·기타 오류 로그·실제 화면 결과를 함께 확인해야 합니다.

증상이 사라지면 추가 합성/색상 텍스처 전달 경로를 우선 조사할 근거가 됩니다. 남으면 NR 실행과 GPU 동기화 등 다른 부분을 계속 구분해야 합니다. 두 경우 모두 피부 보정을 정상적으로 켠 상태의 최종 해결 여부는 별도 확인이 필요합니다.

기존 SkinControl처럼 0.2.4 ASI 해시를 검사하는 도구를 다시 사용하기 전에는 **이 비교본의 `02_RESTORE_PREVIOUS_ADDON.cmd`로 먼저 복구**하십시오. 이번 ZIP에는 전체 모드 재설치나 NR 끄기 버튼이 없습니다.

Windows에서 실제 production `After()`의 원본 descriptor 보존·callback 1회·예외 전달·참조 유지와 적용/복구 도구를 검증합니다. 구체적인 시험 기록은 `evidence`, 빌드 출처와 한계는 `BUILD_PROVENANCE.json`, 해당 소스와 시험 코드는 `SOURCE.zip`에 포함됩니다. Radeon에서 게임을 실행한 화질 검증은 수행하지 않았습니다.
