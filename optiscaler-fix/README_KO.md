# OptiScaler HUDResource RC1

기존 OptiScaler v10의 업스케일링·프레임 생성 설정을 보존하는 실험적 소스 수정본입니다.
메인메뉴 충돌이 해결되었다고 검증된 완성판은 아닙니다.

## 수정 범위

FSR 프레임 생성의 HUD 복사/비교 경로가 오래된 복사 캐시 대신 현재 프레임 기록의 자원을 선택합니다.
이미지 포인터와 GPU 자원 상태를 함께 읽어, 변환된 이미지의 UAV 상태를 COPY_DEST로 잘못 전달하는 경로를 수정합니다.
자원 기록의 잠금을 사용하고 CPU 명령 기록 동안 COM 참조를 보유합니다. GPU 완료 fence를 대신하지는 않습니다.

기준 소스: https://github.com/optiscaler/OptiScaler/tree/7daf5d042d32412da407838cd59e0869ecaaa55e
이 버전은 대화에서 0.10으로 불린 개발 계열이며 upstream 버전 표기는 10.0.0-dev입니다.
업스케일러 알고리즘·FG 구현·입출력 선택·CET 키 설정·게임 설정은 변경하지 않습니다.
HUD cutoff/비교가 꺼져 있거나 HUDless 입력을 사용하지 않는 구성에서는 수정 분기가 실행되지 않습니다.
AMD MLFG 내부의 다른 오류, 모든 메모리 퇴거 문제, 사용자 충돌의 원인 전체를 수정했다고 주장하지 않습니다.

## MO2 설치

1. 게임을 종료하고, 현재 실제 폴더에 배포된 Root Builder 파일을 Clear합니다.
2. 기존 OptiScaler **v10 기본 모드는 켜 둡니다.** 이 ZIP은 기본 설정을 포함하지 않는 덮어쓰기용 모드입니다.
3. `OptiScaler_HUDResource_RC1_MO2.zip`을 MO2의 새 모드로 설치합니다.
4. 왼쪽 모드 우선순위에서 기존 OptiScaler보다 높은 숫자로 배치합니다. 다른 정렬 상태라면 단순 위/아래 위치로 판단하지 마십시오.
5. `Overwrite/Root/bin/x64/dxgi.dll` 또는 같은 `OptiScaler/` 하위 경로에 이전 사본이 남아 있다면 새 파일보다 우선할 수 있습니다. `Overwrite/bin/x64`도 해당 프로필에서 사용 중이면 확인합니다. 충돌하는 OptiScaler 파일만 별도 보관하고 패치 모드 파일이 승리하도록 합니다. Overwrite 전체를 삭제하지 마십시오.
6. 기존 Root Builder Copy 방식으로 MO2에서 실행합니다. OptiScaler 화면/로그의 버전명에 `[HUDResource-RC1]` 표시가 있어야 이 DLL이 적용된 것입니다.

`OptiScaler.ini`를 동봉하지 않아 기존 화질·프레임 생성 설정을 유지합니다.
DLL과 기준 소스에 묶인 보조 런타임은 `Root/bin/x64/OptiScaler/` 구조로 포함됩니다.
0.9.4 폴더에 DLL만 임의로 섞어 넣는 용도가 아닙니다. CET의 `version.dll`은 변경하지 않습니다.
현재 OptiScaler 본체가 `dxgi.dll`이 아닌 `winmm.dll` 또는 ASI 방식이라면 이 ZIP의 dxgi 방식과 중복으로 켜지 않도록 기존 OptiScaler 로더를 먼저 구분해야 합니다. 이름만 보고 CET나 다른 프로그램의 DLL을 삭제하지 마십시오.
사용자가 지정한 런타임 경로나 Overwrite 우선 파일이 있으면 동봉 런타임 대신 그 파일이 선택될 수 있습니다.
복구는 게임 종료 → Root Builder Clear → 이 패치 모드 체크 해제입니다.

## 검증

원본 코드의 오래된 복사본 선택·변환 이미지 상태 오인·프레임 초기화 후 잔존 복사본 선택을
독립 C++ 회귀 테스트에서 재현한 뒤 수정 코드를 확인했습니다.
테스트의 D3D12/COM 타입은 모형이므로 GPU 드라이버 실행 검증과는 다릅니다.
Windows MSBuild 빌드 성공 여부와 파일 해시는 `BUILD.json`에 기록됩니다.
빌드 성공은 실제 Cyberpunk에서의 안정성 보증이 아닙니다.

소스 수정은 `hudless-current-frame.patch`, 독립 검토 범위는 `REVIEW.md`를 확인하십시오.
공개 GitHub 저장소에는 게임 덤프, 개인 로그, 사용자 설정을 넣지 않습니다.
