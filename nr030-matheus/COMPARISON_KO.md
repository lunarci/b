# 원본·Yuri 비교와 0.2.0 적용 범위

기존 0.1.0의 추가 ASI에 두 소스의 유용한 원리를 통합한 실험판입니다. 두 프로젝트의 DLL이나 NR 모델을 함께 설치하는 방식은 아닙니다.

## 비교 기준

- matiasLombo: `333038704896d6e38f735b9ddb6e62210e509cb9`, `src/codec.hlsl.h`의 RestoreRange 및 코덱·효과 혼합.
- Yuri: `v0.7.0-experimental.1`, `0c123fc4bb81bbcb343246e3c98a3bcb33a1009c`, 같은 파일의 RestoreRange, HighlightShoulder, GamutChromaScale, DetailGain, ScaledDepthWeight, ReconstructedScaledNeural.
- 기존 Matheus 추출과 AMD 0.3.0 연결부: `ecc7b4d6ef7fcef9c73a1b033d3ff9b15b58e192`.

| 기능 | matiasLombo 원본 | Yuri 포크 | 이번 적용 |
|---|---|---|---|
| 색상 보존 | RGB 공통 밝기 배율로 원본 색 비율 보존. NR 색 변화는 줄어듦 | 같은 원리 계승 | 기존 합성 결과의 밝기 변화를 원본 RGB에 전달하도록 재구현. 강도 조절 가능 |
| 어두운 부분 | 거의 검은 입력의 불안정한 나눗셈 방지 | 같은 보호 유지 | 거의 검거나 음수인 원본은 색 보존 모드에서 그대로 유지 |
| 밝은 부분 | 원본 HDR 범위에 효과 복원 | 하이라이트 입력 곡선도 개선 | 합성 출력의 공통 RGB 배율에 FP16 한계를 적용해 채널별 잘림으로 인한 색 변화를 억제 |
| 축소 결과 경계 | 이 축소 경계 처리 없음 | 깊이 차이가 큰 곳의 잔차 완화 | 전체 크기 깊이를 읽는 보호를 기존 합성 패스에 추가 |
| NR 입력 인코딩 | 노출·톤 매핑·sRGB 입력과 복원이 한 쌍 | 완만한 하이라이트 곡선·색역 압축 | AMD 내부 코덱 대체 계약이 없어 제외. 한쪽만 추가하면 중복 변환 가능 |
| 디테일·조명 조절 | 공통 효과 강도 조절 | 주변 픽셀의 로그 밝기 변화 분리 | 최종 효과 강도만 채택. 추가 필터는 내부 proxy 의존성과 연산·과장 가능성 때문에 제외 |
| GPU 자원 수명 | 프레임 생성에서 드러난 재사용 문제 수정 이력 | fence 기반 관리 강화 | 설치본의 기존 queue/fence/command-list Reset 추적 유지. 후킹 코드 중복 없음 |
| 추론 건너뛰기 | cadence·효과 재투영 기능 | 관련 처리 계승·변경 | 동기식 AMD NR과 XeFG 타이밍 변경이 필요한 별도 작업이므로 제외 |
| NR 입력 축소 | 여러 성능 실험 | 물리적 축소·잔차 합성 통합 | 기존 Matheus 면적 평균 축소와 기본 85% 유지 |

## 적용 방식과 한계

원본·Yuri 코덱은 네트워크에 넣은 bounded sRGB proxy와 결과를 직접 다룹니다. 이 추가 ASI는 **AMD 모듈이 복원·합성해 돌려준 저해상도 색 영상**을 받습니다. 따라서 SrgbDecode, 노출 추정, 하이라이트 곡선을 복사하지 않고 기존과 같은 색 표현에서 최종 잔차의 밝기 변화만 옮깁니다. 원본 코덱 전체의 HDR 복원과 같다는 뜻은 아니며, AMD 내부에서 이미 사라진 하이라이트 정보를 되살리지도 못합니다.

`ColourPreservationPercent=100`은 원본 RGB 비율을 우선하므로 NR이 만든 색조 변화도 줄어듭니다. 항상 더 좋은 화면이라는 보장은 없습니다. 0은 이전 Matheus 색 합성, 중간 값은 둘의 혼합입니다. 음수 RGB와 거의 검은 원본은 색 보존 모드에서 변경하지 않습니다.

깊이 보호는 Yuri의 원시 깊이 상대 변화량 기반 휴리스틱입니다. 카메라 투영을 풀어 실제 거리를 구하거나 모든 경계를 정확히 분류하지 않습니다. 유한한 큰 경계의 잔차를 25%까지 줄이고, NaN/Inf 깊이는 보정을 생략합니다. 평평한 깊이에서는 기존 보정 강도를 유지하지만 경계의 NR 효과는 약해질 수 있습니다.

기존 합성 셰이더에 통합하여 별도의 전체 화면 패스나 텍스처 할당을 추가하지 않았습니다. 깊이 5회 읽기와 산술 연산은 추가되므로 비용이 0은 아닙니다. 목적은 화질 비교이며 FPS·입력 지연 수치는 측정하지 않았습니다.

## 비교 설정

게임과 MO2 종료 후 설치된 MatheusNR030.ini에서 변경하고 재실행합니다.

| 대상 | ScalePercent | ColourPreservationPercent | DepthProtection | EffectPercent |
|---|---:|---:|---:|---:|
| 이번 기본값 | 85 | 100 | 1 | 100 |
| 이전 0.1.0 합성 계산 | 85 | 0 | 0 | 100 |
| 색 보존만 | 85 | 100 | 0 | 100 |
| 경계 보호만 | 85 | 0 | 1 | 100 |
| 기본 NR 경로 | 100 | 무시 | 무시 | 무시 |

EffectPercent=0은 합성 효과만 없애며 NR 실행 비용은 남습니다. 추가 모듈을 끄려면 Enabled=0을 사용합니다. ScalePercent=100에서는 이번 합성도 실행되지 않습니다.

## 검증

생산용 셰이더를 Windows D3D12 WARP에서 실행하여 색 비율, FP16 HDR 한계, 경계 감쇠, 원본 보존, 이전 합성 모드와 강도 조절을 검사합니다. 설치·제거·복구와 로그 판독은 Windows PowerShell 5.1에서 검사합니다. 실제 결과는 BUILD_PROVENANCE.json과 evidence에 있습니다. Radeon 게임 실행과 품질·성능 우열은 아직 확인하지 않았습니다.

## 소스와 라이선스

- https://github.com/matiasLombo/neural-upstream/blob/333038704896d6e38f735b9ddb6e62210e509cb9/src/codec.hlsl.h
- https://github.com/yuriimatysik/neural-upstream/blob/0c123fc4bb81bbcb343246e3c98a3bcb33a1009c/src/codec.hlsl.h
- https://github.com/lunarci/b/tree/ecc7b4d6ef7fcef9c73a1b033d3ff9b15b58e192/nr030-matheus

두 neural-upstream 소스의 MIT 고지를 third_party/neural-upstream_LICENSE.txt에 포함했습니다. 전체 추가 모듈은 GPL-3.0-only이며 수정 소스는 SOURCE.zip에 있습니다.
