# Matheus NR030 0.2.4 휘도 보정 안정화 설치본

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

## 이번 수정과 확인된 범위

기존 색 보존은 원본 RGB 비율을 유지하면서 NR의 밝기 변화를 전달합니다. 0.2.4는 **원본에 비해 NR이 추가한 국소적인 밝기 대비**를 검사해 과도한 보정량을 약화합니다.

- 원본 피부 텍스처나 전체 화면을 흐리지 않습니다. 기존 NR 보정량에만 0~1의 감쇠 계수를 적용합니다.
- 각 저해상도 픽셀에 고정된 주변 값을 사용하고 색·깊이가 다른 이웃의 기여를 제한합니다.
- 이전 0.2.3의 픽셀별 제한 후 보간 순서와 각 저해상도 픽셀의 0 보정량을 유지합니다. 서로 반대인 보정의 상쇄 정도는 달라질 수 있습니다.
- 원래 노이즈를 줄이는 NR 보정과 일정한 HDR 입력·보정이 유지되는지 별도 검사합니다.
- 피부나 흰색 조명을 판별하는 마스크가 아닙니다. 해당 관찰만으로 원인을 확정하지 않습니다.

기본값은 `ScalePercent=85`, `ColourPreservationPercent=100`, `DepthProtection=1`, `EffectPercent=50`, **`LumaStabilityPercent=100`**입니다. 이전 INI에 없는 새 키는 설치 시 추가하며 직접 조정한 키는 보존합니다. 실제 적용값은 3번 결과의 `LumaStabilityPercent`로 확인합니다.

`LumaStabilityPercent=0`은 이번 억제 기능만 꺼서 기존 0.2.3 합성과 비교하는 값입니다. NR 처리 자체는 계속됩니다. 파일은 게임·MO2를 종료한 뒤 수정하고 새 게임 실행에 적용합니다. ARK와 overwrite 양쪽에 같은 INI가 있으면 실제 적용값을 로그로 확인해야 합니다.

원본 영상 자체에 있던 자글거림, 넓은 영역이 프레임마다 함께 변하는 밝기, 프레임 생성 잔상까지 해결한 것은 아닙니다. 거친 NR 보정과 함께 유효한 밝기 변화나 미세 대비도 약해질 수 있습니다. 새 텍스처·이전 프레임 누적·추가 dispatch는 없지만 이웃을 읽는 연산이 늘어나므로 실제 성능은 게임에서 비교해야 합니다.

NR 입력은 가로·세로 각각 85%이고 최종 NR 보정 합성 강도는 50%입니다. 이번 안정화 100%가 NR 효과 100%를 뜻하지 않습니다. 설치 시 업스케일 배율 2.0을 유지하고 기존 FSR·XeFG 실행 파일은 교체하지 않습니다.

같은 저장 위치·조명에서 피부 자글거림과 팔 움직임을 확인합니다. 실게임 화질 개선은 아직 검증하지 않았습니다. 기존 4번은 두 NR의 INI 활성 설정을 꺼서 비교하는 기능이며 ASI 파일 로딩 자체를 차단하는 기능은 아닙니다.

## 실행 결과 확인

3번의 `ScalePercent=85`는 설정값입니다. `scaled`, `nr_recorded`, `resolved` 증가와 실제 입력·NR 크기를 함께 확인해야 합니다. 요청한 2.0 배율로 4K 출력이면 입력 1920×1080, 85% NR 크기는 1632×918입니다. 1.5 배율의 예전 입력 2560×1440에서는 2176×1224였습니다. 3번은 배율 설정도 검사하지만 실제 게임 오버레이의 입력·출력 크기를 함께 확인해야 합니다. `fallback`은 우회 횟수이며 성공 횟수가 아닙니다.

설치 완료·`hook_active`만으로 화질·성능 개선을 입증할 수 없습니다. GPU 명령 기록과 GPU 완료도 구분해서 표시합니다. `Results\MATHEUS_CHECK.txt`와 맵 전후 FPS를 함께 보내주십시오.

## 보존·지원 범위

기존 OptiScaler·Intel 프레임 생성 실행 파일, 출력 해상도·샤프닝 등 관련 없는 설정을 보존합니다. **전체 업스케일 배율은 요청대로 2.0으로 설정하고 품질별 배율 덮어쓰기는 끕니다.** NR 실행에 필요한 INI 키와 관리 대상 파일도 백업 후 변경합니다. 4번 NR 끄기는 2.0 배율을 유지하고, 5번 통합 복원은 설치 직전 배율도 복원합니다. 통합 설치 백업은 MO2 아래 `Matheus_NR030_Complete_Backup`, 추가 모드 기록은 `Matheus_NR030_Addon_Backup`, 다운로드 캐시는 압축을 푼 폴더의 `download-cache`에 있습니다.

현재 정상 작동하는 MO2·OptiScaler·XeFG와 AMD 드라이버를 전제로 합니다. 그래픽 드라이버를 설치·교체하는 패키지는 아닙니다. AMD HIP 7을 찾지 못하면 필요한 드라이버 구성요소를 표시합니다. 기본 NR 처리와 XeFG 4X의 실제 동작은 각각의 실행 기록으로 확인해야 합니다.

**Windows 빌드·셰이더·설치 시험과 Radeon 게임 검증은 다릅니다.** 피부 모자이크, 움직임 잔상, FPS 악화가 모두 해결됐다고 보장하지 않습니다. 실제 수행한 시험은 `BUILD_PROVENANCE.json`, `BUILD_STATUS_KO.md`, `evidence`를 기준으로 확인하십시오.

## 출처

- 기본 NR: [GitHub XeFG 호환 ZIP](https://github.com/user-attachments/files/32174452/XeFG.opti.zip)의 `version-original.dll`만 사용합니다. 함께 든 다른 OptiScaler DLL은 사용하지 않습니다.
- 모델 310.8.0.0: [RankFTW 공개 미러](https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0/nvngx_dlssnr_310.8.0.zip). NVIDIA 공식 배포처가 아닌 미러이며 검증된 기존 모델을 우선 재사용합니다.
- [AMD HIP 배포 지침](https://rocm.docs.amd.com/projects/install-on-windows/en/latest/conceptual/deployment-guidelines.html): HIP 런타임은 AMD 드라이버 구성요소입니다.

기본 NR·NVIDIA 모델은 이 ZIP에 재배포하지 않고 설치 시 지정 출처에서 받습니다. 추가 모드 소스는 `SOURCE.zip`, 라이선스와 출처는 `LICENSE`, `NOTICE`, `third_party`에 있습니다.
