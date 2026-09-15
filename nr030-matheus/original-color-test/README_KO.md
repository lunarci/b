# NR 원본 화면 전달 비교본 — 자동 설정판

이전 설치기의 `EffectPercent=0` 요구 오류를 수정했습니다. **01번이 기존 보정 강도를 백업하고 비교에 필요한 Effect 0을 자동으로 설정합니다.** 사용자가 INI를 먼저 편집할 필요가 없습니다. 기존 설치 기록이 없어도 실제 파일을 검증하여 적용합니다.

기존 비교본과 ASI는 동일합니다. 이번에는 설치·복원 도구만 수정했습니다. 흰색 깨짐이나 피부 자글거림이 해결됐다고 검증한 최종 그래픽 수정본은 아닙니다.

## 실행 순서

게임과 MO2를 종료하고 다운로드 폴더 등 원하는 새 폴더에 ZIP 전체를 풉니다. 아래 CMD가 있는 폴더에서 실행합니다. 기본 대상은 `C:\CYBERPUNK_ARK_PACK_MO2`입니다.

1. **01_APPLY_ORIGINAL_COLOR_TEST.cmd** 실행: 기존 ASI·보정 강도·설치 기록을 백업하고 비교본과 Effect 0을 적용합니다.
2. 평소처럼 MO2에서 게임 실행: 같은 장면에서 팔 움직임을 비교합니다. NR 입력 85%와 XeFG 5배 설정은 유지됩니다.
3. 게임·MO2 종료 후 **03_COLLECT_LOGS.cmd** 실행: 이 폴더의 `Results`에 생성되는 `MOTION_EVIDENCE-….zip`을 전달합니다.
4. 비교 후 **02_RESTORE_PREVIOUS_ADDON.cmd** 실행: 이전 ASI와 보정 강도를 복원합니다. 처음 설치 기록이 없었다면 새 기록도 제거합니다.

다른 MO2 경로는 CMD의 첫 번째 인수로 지정할 수 있습니다.

```bat
01_APPLY_ORIGINAL_COLOR_TEST.cmd "D:\My MO2"
03_COLLECT_LOGS.cmd "D:\My MO2"
02_RESTORE_PREVIOUS_ADDON.cmd "D:\My MO2"
```

## 변경 내용과 복원

- 기본 NR 0.3.0·모델·OptiScaler·XeFG 실행 파일은 교체하지 않습니다.
- 기존 주 모드와 overwrite의 `MatheusNR030.ini`에서 **EffectPercent만 0으로 준비**합니다. 서로 다른 원래 값도 각각 백업합니다.
- NR 입력 85%, 업스케일 비율, XeFG 활성 및 배율을 변경하지 않습니다. NR 계산은 계속 수행됩니다.
- 원래 Effect 키가 없었다면 복원할 때 추가한 키도 제거합니다. 다른 설정을 바꾸지 않았다면 원래 INI 바이트로 복구하고, 비교 도중 다른 설정을 수정했다면 그 수정은 유지하면서 Effect만 되돌립니다.
- Windows가 설정을 읽을 수 있도록 필요한 경우 편집하는 INI의 인코딩을 UTF-16LE로 저장합니다. 원본 파일은 그대로 백업됩니다.
- 같은 비교본을 다시 적용해도 최초 백업을 덮어쓰지 않습니다. 적용 후 Effect를 다시 바꾼 상태라면 02번으로 복구한 뒤 01번을 실행하십시오.
- 손상된 설치 기록, 다른 ASI, 중복된 INI 키는 자동으로 덮어쓰지 않습니다. 중단 메시지에 표시된 문제가 있다면 그 내용을 확인해야 합니다.

## 무엇을 비교하는가

Effect 0은 NR 계산을 끄는 설정이 아닙니다. 이번 ASI는 NR 계산·85% 입력 처리를 수행한 뒤, Effect 0에서는 추가 합성과 색상 텍스처 교체를 생략하고 원래 색상 텍스처를 FSR에 전달합니다. 이때 NR의 시각적 보정은 섞지 않습니다.

새 게임 세션의 `MatheusNR030.log`에서 아래 항목을 확인합니다.

```text
event=effect_zero_handoff diagnostic_build=true mode=original_color_passthrough
event=original_color_stats passthrough=...
```

`passthrough`가 0보다 크면 원본 색상 전달 분기를 거쳤다는 뜻입니다. 합성을 생략하므로 `resolved=0`이 예상됩니다. 기존 검사기에 `NO_NR_RESOLVE_RECORDING_OBSERVED`라고 나올 수 있으므로 새 passthrough 카운터와 실제 화면을 함께 판단합니다.

기존 ASI의 Windows 빌드와 handoff 검증은 유지합니다. 이번 설치 도구는 Windows PowerShell 5.1에서 보정 강도 50·100·키 없음·설치 기록 없음, INI 읽기 및 복구를 검사합니다. 기록은 `evidence`, 출처는 `BUILD_PROVENANCE.json`, ASI 소스는 `SOURCE.zip`, 이번 설치 도구 소스는 `INSTALLER_SOURCE.zip`에 있습니다. 실제 Radeon 게임의 화질·지연 개선은 확인 전입니다.
