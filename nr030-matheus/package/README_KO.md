# Matheus NR030 0.2.2 통합 설치본

재윤님의 `C:\CYBERPUNK_ARK_PACK_MO2`와 기존 OptiScaler FSR·Intel XeFG 4X 구성에 사용하는 설치본입니다. 필요한 기본 NR·모델 파일을 찾아 검증하고, 없으면 지정한 배포처에서 자동 다운로드합니다. 추가 모드 ASI는 ZIP 안에 들어 있습니다.

## 실행 방법

1. ZIP 속성에 **차단 해제**가 있으면 적용합니다.
2. `C:\NR_Complete` 같은 일반 폴더에 **전체 압축을 풉니다.** 특정 게임 폴더에 풀 필요가 없습니다.
3. 게임과 MO2를 종료하고 **`01_INSTALL_ADDON.cmd`**를 실행합니다. CMD와 `Complete-Setup.ps1`, `Setup.ps1`, `payload` 폴더는 함께 있어야 합니다.
4. 설치 완료 메시지가 나오면 평소처럼 MO2에서 게임을 실행합니다.

설치 대상: `C:\CYBERPUNK_ARK_PACK_MO2\mods\ARK_OptiScaler_\Root\bin\x64\plugins`

기본 NR 또는 모델이 없으면 약 10.5 MiB·104.4 MiB의 ZIP을 다운로드합니다. ZIP과 추출 파일 모두 크기·SHA-256을 확인하며, 준비가 끝난 뒤 게임 파일을 변경합니다. 같은 파일이 이미 있으면 재사용합니다. 다운로드 실패 시 게임을 종료한 상태에서 1번을 다시 실행할 수 있습니다.

## 버튼

| 파일 | 동작 |
|---|---|
| `00_FIX_RATIO_AND_DISABLE_NR.cmd` | 기존 배율을 **2.0으로 수정하고 두 NR을 함께 끔**. 새 DLL 없이 현재 설정 복구 |
| `01_INSTALL_ADDON.cmd` | NR·모델 준비, 전체 업스케일 배율 2.0 적용, 설정·백업, 추가 모드 설치 또는 갱신 |
| `02_REMOVE_ADDON.cmd` | Matheus 추가 모드만 제거. 기본 NR은 유지 |
| `03_CHECK_ADDON.cmd` | 최근 실행 로그를 읽어 `Results\MATHEUS_CHECK.txt` 생성 |
| `04_RESTORE_FSR_XEFG.cmd` | **기본 NR과 추가 모드를 함께 끔.** 피부·잔상·성능 문제 시 기존 FSR·XeFG 경로로 비교 복귀 |
| `05_REMOVE_AND_RESTORE_BASE.cmd` | 추가 모드를 제거하고 이번 통합 설치가 바꾼 기본 NR·설정을 복원. 이후 직접 바꾼 파일과 충돌하면 중단 |

0·1·2·4·5번은 게임과 MO2를 종료한 뒤 실행합니다. 4번으로 끈 후 다시 NR을 적용하려면 1번을 실행하고 게임을 새로 시작합니다. 5번은 기본 NR·모델·설정을 설치 직전 상태로 복원하며 예전 추가 모드를 자동으로 재설치하지 않습니다. 화면·지연 비교에는 4번을 사용합니다.

## 이번 수정과 기본값

- 이전 사용자 로그는 `scaled=0 / resolved=0 / fallback=1080`으로, 85% 처리가 실행되지 않았습니다.
- 이전 게임 로그에 기록된 **RGBA16F 4채널 모션벡터**를 지원합니다. 실제 형식으로 읽어 XY 이동값만 축소 영상에 전달합니다.
- 축소 처리에 들어가기 전 입력 검사에서 거부되면 **NR을 생략하고 원래 FSR 입력으로 우회**합니다. 85% 처리 실패 시 비용이 큰 원래 크기 NR을 계속 실행하던 동작을 바꿨습니다.
- 우회 사유와 실제 색상·깊이·모션 형식, 크기를 기록합니다. 검사 결과에 기본 NR의 입력 형식과 처리 시간도 포함합니다.
- NR 파일 누락과 해시 불일치를 별도로 표시합니다. 이전 v1.4 기록이 없어도 실제 파일을 검증해 설치합니다.
- 요청하신 **OptiScaler 전체 배율 2.0**을 설치 시 적용합니다. 4K 출력 기준 입력은 1920×1080입니다. 이전 1.5는 2560×1440 입력이어서 처리 픽셀 수가 더 많았습니다.
- 완료된 GPU 자원 참조 정리와 유휴 추가 버퍼 축소는 유지합니다.

새 설치 기본값: `ScalePercent=85`, `ColourPreservationPercent=100`, `DepthProtection=1`, `EffectPercent=50`.

NR 입력의 가로·세로를 각각 85%로 줄이고 NR 보정 결과를 절반 강도로 원래 입력에 합성한 뒤 기존 FSR·XeFG 경로로 넘깁니다. 50%는 과한 피부 변화·노이즈를 줄여 보기 위한 시작값이며 실제 화질 개선을 검증한 수치는 아닙니다. NR 처리 시간을 절반으로 만드는 설정도 아닙니다. 기존에 직접 조정한 추가 모드 INI는 갱신 시 보존될 수 있으므로 실제 적용값은 3번 결과를 확인하십시오.

같은 저장 위치·시선·그래픽 설정에서 1번 적용 상태와 4번 NR 끔 상태를 비교합니다. 맵을 열기 전, 닫은 직후, 10~30초 뒤 FPS와 피부·잔상을 확인하십시오. `ScalePercent=100`은 원래 크기 기본 NR을 실행하는 별도 비교값이며 NR을 끄는 값이 아닙니다. 모든 설정 변경은 게임 재실행 후 적용됩니다.

## 실행 결과 확인

3번의 `ScalePercent=85`는 설정값입니다. `scaled`, `nr_recorded`, `resolved` 증가와 실제 입력·NR 크기를 함께 확인해야 합니다. 요청한 2.0 배율로 4K 출력이면 입력 1920×1080, 85% NR 크기는 1632×918입니다. 1.5 배율의 예전 입력 2560×1440에서는 2176×1224였습니다. 3번은 배율 설정도 검사하지만 실제 게임 오버레이의 입력·출력 크기를 함께 확인해야 합니다. `fallback`은 우회 횟수이며 성공 횟수가 아닙니다.

설치 완료·`hook_active`만으로 화질·성능 개선을 입증할 수 없습니다. GPU 명령 기록과 GPU 완료도 구분해서 표시합니다. `Results\MATHEUS_CHECK.txt`와 맵 전후 FPS를 함께 보내주십시오.

## 보존·지원 범위

기존 OptiScaler·Intel 프레임 생성 실행 파일, 출력 해상도·샤프닝 등 관련 없는 설정을 보존합니다. **전체 업스케일 배율은 요청대로 2.0으로 설정하고 품질별 배율 덮어쓰기는 끕니다.** NR 실행에 필요한 INI 키와 관리 대상 파일도 백업 후 변경합니다. 4번 NR 끄기는 2.0 배율을 유지하고, 5번 통합 복원은 설치 직전 배율도 복원합니다. 통합 설치 백업은 MO2 아래 `Matheus_NR030_Complete_Backup`, 추가 모드 기록은 `Matheus_NR030_Addon_Backup`, 다운로드 캐시는 압축을 푼 폴더의 `download-cache`에 있습니다.

현재 정상 작동하는 MO2·OptiScaler·XeFG와 AMD 드라이버를 전제로 합니다. 그래픽 드라이버를 설치·교체하는 패키지는 아닙니다. AMD HIP 7을 찾지 못하면 필요한 드라이버 구성요소를 표시합니다. 이번 사용자 실행 기록에서는 기본 NR 작업과 XeFG 4X가 작동해 이 기반 환경이 확인됐습니다.

**Windows 빌드·셰이더·설치 시험과 Radeon 게임 검증은 다릅니다.** 피부 모자이크, 움직임 잔상, FPS 악화가 모두 해결됐다고 보장하지 않습니다. 실제 수행한 시험은 `BUILD_PROVENANCE.json`, `BUILD_STATUS_KO.md`, `evidence`를 기준으로 확인하십시오.

## 출처

- 기본 NR: [GitHub XeFG 호환 ZIP](https://github.com/user-attachments/files/32174452/XeFG.opti.zip)의 `version-original.dll`만 사용합니다. 함께 든 다른 OptiScaler DLL은 사용하지 않습니다.
- 모델 310.8.0.0: [RankFTW 공개 미러](https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0/nvngx_dlssnr_310.8.0.zip). NVIDIA 공식 배포처가 아닌 미러이며 검증된 기존 모델을 우선 재사용합니다.
- [AMD HIP 배포 지침](https://rocm.docs.amd.com/projects/install-on-windows/en/latest/conceptual/deployment-guidelines.html): HIP 런타임은 AMD 드라이버 구성요소입니다.

기본 NR·NVIDIA 모델은 이 ZIP에 재배포하지 않고 설치 시 지정 출처에서 받습니다. 추가 모드 소스는 `SOURCE.zip`, 라이선스와 출처는 `LICENSE`, `NOTICE`, `third_party`에 있습니다.
