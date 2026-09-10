# OptiScaler HUDResource RC1 — 설치

실제 Windows x64 DLL 수정본과 Overwrite 충돌 정리 도구입니다.
기존 OptiScaler v10의 DLSS 입력·FSR 출력·프레임 생성 설정을 유지하는 덮어쓰기용 모드입니다.
Cyberpunk의 충돌 해결이 사용자 PC에서 검증된 완성판은 아닙니다.

1. 게임을 종료하고 MO2에서 **Root Builder → Clear**를 실행합니다.
2. 이 ZIP을 바탕화면 등 게임 밖에 압축 해제하고 **tools/Apply-Overwrite-Fix.cmd**를 더블클릭합니다. 지정된 아크팩 Overwrite에서 이 패키지의 DLL과 겹치는 사본만 외부 백업 후 치웁니다. 게임 폴더, CET, INI, 모드 원본은 수정하지 않습니다. 오류가 나면 변경을 되돌리고 중단하므로 완료 메시지를 확인합니다.
3. **같은 ZIP을 MO2에서 새 모드로 설치**하고, 기존 OptiScaler v10 모드는 켜 둡니다. 새 모드의 **우선순위 숫자가 더 높게** 배치되어야 합니다. 기존 Root Builder Copy 방식으로 실행합니다.
4. OptiScaler 화면 또는 로그의 버전에 **[HUDResource-RC1]** 표시가 있으면 이번 DLL이 적용된 것입니다. 화질·FG 선택을 다시 바꿀 필요는 없습니다.

`Apply-Overwrite-Fix.cmd`는 게임 실행 때마다 실행하는 도구가 아닙니다. 이번 패치를 설치하기 전에 잔존 DLL을 정리하는 일회성 도구입니다. Root Builder Clear를 자동으로 실행하지 않습니다.

현재 OptiScaler를 `dxgi.dll`로 쓰는 v10 모드에 맞춘 ZIP입니다. `winmm.dll`이나 ASI 방식의 OptiScaler를 동시에 켜는 구조에는 그대로 중복 설치하지 마십시오. CET의 `version.dll`을 삭제하거나 변경할 필요가 없습니다.

## 확인과 복원

- `tools/Check-Overwrite.cmd`: 읽기 전용 충돌 확인.
- `tools/Restore-Overwrite.cmd`: 이번 정리의 백업 manifest를 선택해 원래 위치로 복원. 새로 변경된 파일을 덮어쓰지 않습니다.
- 백업: `%LOCALAPPDATA%/OptiScalerHUDResource/Backups/`의 작업별 폴더.
- 패치 자체를 되돌릴 때: 게임 종료 → Root Builder Clear → 새 RC1 모드 체크 해제. 필요하면 위 복원 도구로 Overwrite 백업 복원.

세부 수정 범위는 `_PackageDocs/README_KO.md`, 파일 해시와 실제 빌드·검증 실행 링크는 `_PackageDocs/BUILD.json`, 도구의 상세 범위는 `tools/README_KO.md`에 있습니다.
