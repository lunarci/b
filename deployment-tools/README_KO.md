# Overwrite 충돌 파일 백업

이 도구는 패치 DLL보다 먼저 적용되는 MO2 Overwrite 사본을 별도로 보관합니다. 압축파일 전체를 푼 뒤 사용하세요. `tools`와 `_PackageDocs` 폴더가 같은 위치에 있어야 합니다.

1. Cyberpunk 2077을 종료하고 MO2에서 **Root Builder Clear**를 실행합니다. 이 도구가 Clear를 대신 실행하지는 않습니다.
2. `Check-Overwrite.cmd`로 대상 파일을 확인할 수 있습니다. 검사는 파일을 변경하지 않습니다.
3. `Apply-Overwrite-Fix.cmd`를 실행하면 대상 파일을 외부 폴더에 복사하고 해시를 확인한 후 Overwrite의 해당 사본만 제거합니다.
4. MO2에서 기존 v10 기본 모드와 패치 모드를 켜고, 패치 모드가 우선하도록 설정한 뒤 실행합니다.

기본 위치는 `C:\CYBERPUNK_ARK_PACK_MO2\overwrite`입니다. 없으면 폴더 선택창이 열립니다. 폴더 이름이 `overwrite`인 MO2 폴더 또는 그 아래 `Root\bin\x64`, `bin\x64`를 선택하세요. 이름을 바꾼 사용자 지정 Overwrite 폴더는 이 버전에서 지원하지 않습니다.

대상은 이 빌드의 `_PackageDocs/BUILD.json`에 있는 `dxgi.dll`과 `OptiScaler` 하위 DLL의 정확한 상대 경로뿐입니다. `dxgi.dll`이 OptiScaler인지 확인되지 않으면 전체 작업을 시작하지 않습니다. 게임 폴더, 모드 원본, INI, CET 키 바인딩, `version.dll`, `winmm.dll`, ReShade는 변경하지 않습니다. DLSS 입력·FSR 출력 설정도 유지합니다.

백업은 `%LOCALAPPDATA%\OptiScalerHUDResource\Backups\<작업 ID>`에 저장됩니다. 화면에 표시된 `manifest.json` 경로를 보관하세요. 삭제·복사에 실패하면 처리한 파일을 되돌리고 실패로 종료합니다. 잠긴 파일을 강제로 해제하거나 권한을 바꾸지 않습니다. 복원 중에는 검증한 파일을 같은 폴더의 임시 파일에 준비한 뒤 원래 이름으로 바꿉니다. 임시 파일은 정상 종료나 오류 처리 때 제거됩니다.

복원하려면 게임 종료와 Root Builder Clear 후 `Restore-Overwrite.cmd`를 실행하고 **해당 작업의** `manifest.json`을 고릅니다. 기존 경로에 내용이 바뀐 파일이 생겼다면 덮어쓰지 않고 중단합니다. 전원 차단·강제 종료가 있었다면 백업을 보존하고 같은 작업의 복원을 사용하세요. 디스크나 권한 문제로 자동 복원이 실패하면 화면에 나온 백업 경로의 원본을 보존한 상태로 오류를 확인해야 합니다.

## 화면 없이 실행

```powershell
powershell.exe -NoProfile -File .\tools\Manage-OptiScalerOverwrite.ps1 -Action Check -OverwritePath "D:\MO2\overwrite" -BuildManifestPath ".\_PackageDocs\BUILD.json" -Headless
powershell.exe -NoProfile -File .\tools\Manage-OptiScalerOverwrite.ps1 -Action Apply -OverwritePath "D:\MO2\overwrite" -BuildManifestPath ".\_PackageDocs\BUILD.json" -Headless
powershell.exe -NoProfile -File .\tools\Manage-OptiScalerOverwrite.ps1 -Action Restore -BackupManifestPath "<해당 작업의 manifest.json>" -Headless
```

성공은 종료 코드 0, 실패는 1입니다. 백업 경로를 직접 지정했다면 복원에도 같은 `-BackupBase`를 사용합니다. 폴더의 정션·심볼릭 링크는 따라가지 않고 거부합니다.
