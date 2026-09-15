# 0.2.1 맵 복귀 후 프레임 저하 검토·수정

> 이전 버전의 수정 기록입니다. 0.2.2 통합판은 4채널 모션벡터 지원, 축소 입력 거부 시 첫 호출부터 NR 없이 FFX로 우회, 설치 시 요청한 배율 2.0 적용을 추가했습니다. 현재 사용법은 README_KO.md를 확인하십시오.

## 결론

기존 0.2.0 코드에서 **이미 사용이 끝난 GPU 자원을 오래 붙잡을 수 있는 경로**를 세 가지 관점의 독립 검토가 확인했습니다. 해당 경로를 수정하고, 일시적으로 늘어난 추가 버퍼를 줄이는 처리를 넣었습니다. 이것이 현재 게임의 FPS 고착 원인이라는 실측 증거는 아직 없습니다. 이 파일은 회복 가능성을 높이고 다음 로그로 원인을 구분하기 위한 실험판입니다.

## 원인 후보와 검토 결과

| 후보 | 확인 수준 | 판단·조치 |
|---|---|---|
| 완료된 슬롯의 옛 게임 자원 참조 잔류 | 코드상 확인 | 이전 Acquire는 첫 재사용 슬롯에서 반환하여 뒤쪽 완료 슬롯의 borrowed 참조를 정리하지 않음. 모든 슬롯을 먼저 순회하도록 수정 |
| 일시적으로 늘어난 추가 scratch 상시 보관 | 코드상 확인 | 이전 코드는 최대 512MiB 범위에서 늘어난 자체 텍스처를 줄이지 않음. 완료된 유휴 슬롯을 2초 후 정리, 두 슬롯 유지 |
| VRAM 사용량이 OS 예산 초과 | 현재 발생 여부 미확인 | 위 두 경로가 부담을 더할 수 있음. 실제 프로세스 사용량·예산·회수량 기록 추가 |
| NR 처리 context·해상도·명령 목록 전환 | 보호 우회 경로 존재, 현재 발생 미확인 | 우회 중에도 기존 완료 자원을 회수. 이유를 context_changed / render_extent_changed / device_or_tracking_changed로 구분 |
| XeFG 생성 중단·UI 입력 불일치 | 외부 경로 가설 | 실제 렌더 FPS와 표시 FPS를 구분해야 함. addon은 XeFG 문맥을 소유하지 않아 강제 재시작 제외 |
| 기본 NR의 HIP 작업 지연·임시 자원 | 외부 엔진 가설 | 기본 NR 로그의 대기·재생성 메시지 필요. 타 엔진 자원을 강제 해제하지 않음 |
| 게임 맵·스트리밍·다른 모드의 자원 유지 | 가설. addon 이전 유사 증상 이력 있음 | 우리 불필요한 참조를 해제해 게임이 자원을 해제할 기회를 제공. 게임 자체 누수 해결로 단정하지 않음 |
| 드라이버·전력 상태·그래픽 상태 문제 | 직접 증거 없음 | 이번 패키지에서 해당 설정을 변경하지 않음 |

NR 우회 자체는 원 FFX를 호출하며, 이미 축소 NR이 시작된 뒤 100% NR을 새로 실행하는 경로가 아닙니다. 따라서 '맵을 닫으면 100% NR로 바뀌어서 느려졌다'는 설명은 이 코드와 맞지 않습니다. XeFG의 정상적인 한 번의 history reset도 영구적인 프레임 저하와 구분해야 합니다.

## 변경 내용

1. NR 입력을 받아 처리하기 전에 전체 슬롯을 순회합니다. GPU 제출 관측, 모든 fence 완료, 성공한 command-list Reset이 모두 확인된 슬롯의 보유 참조를 내려놓습니다. 앞쪽 슬롯 하나를 찾았다고 정리를 멈추지 않습니다.
2. context·입력 크기 변경 등으로 추가 기능을 우회할 때도 같은 정리를 수행합니다.
3. 추가 scratch가 두 슬롯을 초과하면, 사용 기록이 안전하게 회수되고 2초 이상 쓰지 않은 슬롯부터 줄입니다. 게임 호출이 계속되어야 정리가 실행됩니다. 2초가 FPS 회복 보장 시간이라는 뜻은 아닙니다.
4. 기본 85% 입력 축소, 색상 보존, 깊이 경계 보호, FFX descriptor 복원은 그대로 유지합니다.
5. GPU 사용량과 처리·회수 누적 횟수를 약 1초 간격으로 로그에 기록하고 3번 검사기에 요약을 추가합니다.

자원 수명 검토에서 현재 C7 NR의 이전 입력 포인터 저장은 변경 로그용이며, staging 재생성은 색 형식·실제 크기를 비교하는 것으로 확인했습니다. 같은 크기의 완료 scratch를 정리하고 다시 만드는 것만으로 NR 크기를 바꿔 재초기화하는 것은 아닙니다.

## 변경하지 않은 안전 조건

시간이나 프레임 수만으로 GPU 사용 완료를 가정하지 않습니다. Reset되지 않은 목록, 관찰되지 않은 제출, 미완료 fence, 알 수 없는 사용 상태는 계속 보관합니다. 이런 슬롯이 실제로 누적된 경우에는 이번 정리만으로 해결되지 않습니다.

CPU/GPU 강제 대기, NR 내부 주소에 강제 reset 쓰기, XeFG 강제 재초기화, 해상도를 바꿨다가 되돌리는 처리는 없습니다. FFX context가 새로 바뀐 경우의 자동 재가입도 이번 변경에 포함하지 않습니다. 로그로 그 경우를 확인한 뒤 별도로 검토해야 합니다.

## 메모리 규모

85%에서 슬롯당 자체 scratch는 `16×NR 픽셀 + 8×원본 입력 픽셀` 바이트입니다. 할당 패딩을 제외하면 1920×1080 입력 약 38.68MiB, 2560×1440 입력 약 68.77MiB입니다. 1440p 입력에서 슬롯이 2개에서 7개로 늘면 자체 scratch 약 343.8MiB가 더 남을 수 있습니다. 여기서 입력은 최종 모니터 해상도가 아니라 업스케일링 전 게임 입력입니다.

borrowed는 새 복사가 아니라 게임·NR 자원의 COM 참조입니다. 이 참조들이 실제로 붙잡는 고유 VRAM 용량은 공유 여부에 따라 달라지므로 슬롯 수에 단순 곱하지 않습니다. 해제한 참조 수나 누적 trimmed_bytes도 실제 VRAM 감소량과 같지 않습니다.

## 비교 플레이

1. 게임·MO2 종료 후 01_INSTALL_ADDON.cmd로 설치합니다. 기본값은 85%, 색·깊이 보호 켬, TrimIdleScratch=1, Diagnostics=1입니다.
2. 같은 저장 위치에서 30초 정도 움직이며 평상시 FPS를 확인합니다.
3. 맵을 5~10초 열었다 닫고 같은 장면에서 10~30초 동안 FPS 회복 여부를 봅니다. 가능하면 같은 과정을 2~3회 반복합니다.
4. 곧바로 03_CHECK_ADDON.cmd를 실행합니다. Results/MATHEUS_CHECK.txt에 최근 세션의 요약과 최근 풀 샘플 최대 90개가 들어갑니다.
5. 결과 확인에는 MATHEUS_CHECK.txt, MatheusNR030.log, dlssnr_on_amd.log, OptiScaler.log와 '맵 전 FPS / 맵 직후 FPS / 10~30초 뒤 FPS'가 필요합니다. 실제 렌더 FPS와 프레임 생성 후 표시 FPS를 구분할 수 있으면 함께 기록합니다.

직접 수정한 이전 INI 때문에 1번 설치기가 중단하면 게임·MO2를 종료하고 02_REMOVE_ADDON.cmd로 추가 모듈만 제거한 뒤 01을 실행합니다. 02는 조정한 INI를 백업합니다. 기본 NR을 제거하는 옛 v1.4 제거 명령은 사용하지 않습니다.

## 로그 해석

| 필드 | 의미 |
|---|---|
| retired_uses / released_borrowed_refs | 안전하게 정리한 사용 기록·참조의 누적 개수 |
| allocated_bytes / allocated_slots | 현재 addon 자체 scratch 할당량·슬롯 수 |
| trimmed_bytes / trimmed_slots | 유휴 정리로 해제한 자체 scratch의 누적량·횟수 |
| retained_uses | 아직 안전한 회수가 증명되지 않은 기록 수. 많다고 바로 누수 판정 불가 |
| local_usage_bytes / local_budget_bytes | 해당 게임 프로세스의 DXGI local 사용량·OS 예산. addon만의 사용량이나 GPU 총 용량이 아님 |
| local_valid | 조회 성공 여부. 0 또는 budget=0이면 예산 상태 판정 불가 |
| nonlocal_usage_bytes | 보조 시스템 메모리 관측값. 증가만으로 퇴거나 누수 확정 불가 |
| seen / scaled / resolved / fallback | 누적 처리 횟수. 샘플 간 증가량으로 추가 경로가 계속 실행되는지 판단 |
| last_fallback_ever | 과거 마지막 우회 이유. 현재 우회가 계속된다는 뜻이 아님 |
| reset_dispatches | 관측한 FFX reset 요청의 누적 dispatch 수. NR·XeFG 내부 reset 횟수가 아님 |
| ffx_frame_time_ms | 게임이 넘긴 FFX 시간 필드. 직접 측정한 GPU 시간이나 FPS가 아님 |

## 검증과 출처

WARP에서는 기존 생산용 셰이더 검사 외에 production lifetime.cpp와 실제 MinHook·D3D12 큐로 제출·Reset·펜스·재실행 수명 조건을 검사합니다. CPU 풀 회귀 검사는 뒤쪽 완료 슬롯 정리, 이중 회수 방지, 유휴 축소 조건을 확인합니다. 실제 통과 결과는 BUILD_PROVENANCE.json과 evidence에 있습니다. Radeon 맵 복귀 FPS는 아직 미측정입니다.

- Microsoft 프로세스 GPU 예산·사용량과 예산 초과 시 끊김 설명: https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiadapter3-queryvideomemoryinfo
- Microsoft 다중 큐 fence 동기화: https://learn.microsoft.com/en-us/windows/win32/direct3d12/user-mode-heap-synchronization
- Intel XeFG history reset·Present 상태·UI 입력 오류: https://github.com/intel/xess/blob/main/doc/xess_fg_developer_guide_english.md
- 기준 설치본: https://github.com/lunarci/b/tree/40b19fc39a8adaa84d337b182b5830bf0942a204/nr030-matheus
