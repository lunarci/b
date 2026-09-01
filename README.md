# ArchiveXL 1.27.1 + PR #22 GitHub Actions 빌더

이 저장소는 Windows PC에 빌드 도구를 설치하지 않고 GitHub Actions에서 다음 시험판을 만듭니다.

```text
ArchiveXL 실제 1.27.1 소스 55f48569f415b443debba4f4ad4cf241194cd06e
+ PR #22의 ResourcePatch appearance-map 수정(+5/-1)
= ArchiveXL-1.27.1-PR22-Test.zip
```

`v1.27.1` 태그는 실제로 이전 `e260b82` 커밋을 가리키므로 사용하지 않습니다. 이 빌더는 1.27.1 버전·patch-token 잠금 수정이 들어 있는 `55f48569`를 커밋 해시로 직접 고정합니다. PR 전체 브랜치(`c251379`)도 사용하지 않으므로 1.28 프리릴리스 변경은 섞이지 않습니다.

## 실행 방법

1. 제공된 빌더 ZIP을 먼저 PC에서 해제한 뒤, 그 안의 **내용 전체**를 새 GitHub 저장소 루트에 올립니다. ZIP 파일이나 바깥쪽 부모 폴더만 올리면 Actions가 생기지 않습니다. 업로드 후 루트에 `.github/workflows/build-archivexl-pr22.yml`과 `.gitattributes`가 보이는지 확인합니다.
2. 저장소의 **Actions** 탭에서 **Build ArchiveXL 1.27.1 with PR 22 fix**를 선택합니다.
3. **Run workflow**를 누릅니다. 별도 입력값이나 Secret은 필요 없습니다.
4. **초록 체크로 성공한 실행만** 열고, **Artifacts**에서 `ArchiveXL-1.27.1-PR22-...`를 받습니다. 이름에 `BUILD-FAILED`가 들어간 artifact는 진단 로그뿐이며 설치하면 안 됩니다.
5. 압축을 푼 뒤 `ArchiveXL-1.27.1-PR22-Test.zip`만 MO2에 별도 모드로 설치합니다.

기존 ArchiveXL은 비활성화하고 시험판만 활성화하는 방식이 가장 명확합니다. 되돌릴 때는 시험판을 끄고 기존 ArchiveXL을 다시 켜면 됩니다.

## Actions가 자동으로 확인하는 것

- Windows Server 2022, MSVC x64, Xmake 3.0.9 사용
- Xmake 자체 ZIP SHA-256 검증
- ArchiveXL 베이스 커밋과 네 개 서브모듈 커밋·URL 검증
- 올려주신 공식 1.27.1 ZIP 및 DLL SHA-256 검증
- 같은 러너·의존성으로 무패치 대조군을 먼저 빌드
- PR 패치가 정확히 한 파일에 `+5/-1`만 적용됐는지 검증
- Release와 진단용 ReleaseDbg를 완전히 다시 빌드
- 최종 ZIP 파일 목록이 공식판과 같고 DLL 외 26개 파일의 해시가 모두 같은지 검증
- x64 PE, ProductVersion 1.27.1, exports `Main`/`Query`/`Supports`, DLL 의존성 검사
- 빌드 로그, 적용 diff, 도구 버전, dependency lock, 모든 결과물 SHA-256 보관

## 산출물 구분

| 경로 | 용도 |
|---|---|
| `ArchiveXL-1.27.1-PR22-Test.zip` | 실제 MO2 시험 설치용 |
| `patched-release/ArchiveXL.dll` | ZIP에 들어간 동일 Release DLL의 별도 사본 |
| `control-DO-NOT-INSTALL/ArchiveXL.dll` | A/B 정적 비교용 무패치 빌드, 설치 금지 |
| `releasedbg-diagnostic-pair/` | 함수명 있는 덤프가 필요할 때만 DLL+PDB를 한 쌍으로 사용 |
| `reports/VERIFICATION.txt` | 자동 검증 결과 |
| `BUILD_MANIFEST.txt` | 소스·도구·러너·해시 이력 |
| `xmake-requires.lock` | 그 실행에서 결정된 외부 의존성 버전 |

ReleaseDbg의 PDB는 Release ZIP의 DLL과 일치하지 않습니다. 진단이 필요하면 `releasedbg-diagnostic-pair` 안의 DLL과 PDB를 반드시 함께 사용해야 합니다.

## 재현성과 안전 범위

ArchiveXL의 `xmake.lua`는 `hopscotch-map`, `minhook`, `spdlog`, `tiltedcore`, `yaml-cpp` 버전을 지정하지 않습니다. 첫 실행은 lock을 생성하고 대조군·패치본 양쪽에 똑같이 사용합니다. 이후에도 같은 의존성을 쓰려면 첫 성공 산출물의 `xmake-requires.lock`을 `locks/xmake-requires.lock`으로 커밋하십시오.

DLL FileVersion에는 빌드 시각이 들어가며 GitHub의 MSVC/SDK 이미지도 갱신될 수 있습니다. 따라서 소스와 의존성 계보는 추적할 수 있지만, 실행할 때마다 DLL 바이트와 SHA-256이 완전히 같다고 보장하지는 않습니다.

Actions의 PASS는 컴파일·패키지·정적 검증 통과를 뜻합니다. Cyberpunk 2077 안에서 장시간 플레이가 안정적이라는 보증은 아닙니다. PR #22는 shared-lock 상태에서 `appearances[{}]`가 맵을 변경할 수 있는 잠재적 쓰기/race 경로를 제거하지만, 다른 모드 오류나 VRAM 부족까지 고치지는 않습니다.

첨부 진단의 해당 크래시는 `0x8` 읽기 access violation만 남고 해결된 ArchiveXL 함수 프레임이 없어 PR #22가 직접 원인이라고 확정할 수 없습니다. 같은 진단에 있는 redscript 중복 `@replaceMethod` 및 TweakXL 타입/값 오류는 이 DLL과 별도로 정리해야 합니다.

## 고정된 근거

- [ArchiveXL 실제 1.27.1 소스 커밋](https://github.com/psiberx/cp2077-archive-xl/commit/55f48569f415b443debba4f4ad4cf241194cd06e)
- [ArchiveXL PR #22](https://github.com/psiberx/cp2077-archive-xl/pull/22)
- [PR #22 제안 커밋](https://github.com/psiberx/cp2077-archive-xl/commit/c2513790d86ed58963060b7f79d23e3f15294732)
- [ArchiveXL 1.27.1 공식 릴리스](https://github.com/psiberx/cp2077-archive-xl/releases/tag/v1.27.1)

공식 패키지의 ArchiveXL 라이선스와 제3자 고지는 최종 ZIP에 원본 그대로 유지됩니다. 감사 artifact에 들어가는 별도 DLL 사본에도 적용되도록 동일 고지를 artifact 최상위와 이 저장소의 `licenses/`에 함께 둡니다.
