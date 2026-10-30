# 한 주 쌓기 (맥 앱 + 위젯)

할 일을 시간 길이만큼의 블록으로 만들어 일주일 판에 쌓는 앱이에요.
화면은 `Resources/index.html`(웹 페이지), 저장과 위젯은 Swift가 맡아요.

## 다운로드

**[⬇︎ HanjuStack.zip](https://github.com/svxcza-oss/report/releases/latest/download/HanjuStack.zip)** — main이 바뀔 때마다 GitHub Actions가 자동으로 새로 빌드해요 (`.github/workflows/hanju-release.yml`).

1. 받아서 풀고 `HanjuStack`을 응용 프로그램 폴더로 옮겨요.
2. 처음 열 때 "확인되지 않은 개발자"로 막히면: 시스템 설정 → 개인정보 보호 및 보안 → **그래도 열기**
   (또는 `xattr -dr com.apple.quarantine /Applications/HanjuStack.app`)
3. 바탕화면 우클릭 → 위젯 편집 → "한 주 쌓기"

## 내 맥에서 직접 빌드 (개발자 계정 필요 없음)

Xcode와 XcodeGen만 있으면 돼요 (`sudo xcode-select -s /Applications/Xcode.app`, `brew install xcodegen`).

```sh
pkill -x HanjuStack
./build-local.sh
rm -rf /Applications/HanjuStack.app && cp -R build/local/Release/HanjuStack.app /Applications/
open /Applications/HanjuStack.app
```

예전 개인용 설치와 같은 저장 파일을 써서 쓰던 계획이 그대로 이어져요. 앱은 샌드박스 없이 위젯 폴더 안의 파일을 직접 같이 써요
(`project.local.yml`, `Config/Local.xcconfig`). 이 방식은 내 맥 전용이고, 앱스토어에는 아래 서명 빌드를 써요.

## 빌드·App Store 준비

전체 Xcode와 XcodeGen을 설치하고 `Config/Signing.xcconfig`에 본인의 Apple Developer Team ID와 고유 Bundle ID를 설정하세요. 앱과 위젯에 같은 App Group을 연결해야 합니다.

```sh
./scripts/check.sh      # 계정 없이 실행 가능한 소스/저장 검사
./build.sh              # 개발자 서명 빌드
./scripts/archive.sh    # App Store용 Universal archive, 자동 업로드 없음
```

계정 생성, 기존 데이터 가져오기와 제출 전 확인은 [APP_STORE.md](APP_STORE.md)에 정리했습니다. 아직 개발자 계정이 없으면 설정의 예시 ID를 실제 ID로 바꾼 다음 서명·실행 검증을 마쳐야 합니다.

## 글꼴

앱·위젯 모두 **나눔고딕**을 앱 안에 넣어서 써요 (SIL Open Font License, `Resources/Fonts/OFL-NanumGothic.txt`). 따로 설치할 필요 없고, 앱스토어 판매에도 쓸 수 있어요.

## 레서

- 앱 안: 화면 아래쪽을 돌아다니다가 가끔 멈춰서 포인터를 쳐다봐요. 누르면 다른 레서로 바뀌어요.
- 바탕화면: 화면 맨 아래(Dock 위)를 돌아다녀요. 상단바 레서 우클릭 → "바탕화면 레서"에서 바탕화면에서 / 모든 창 위에서 / 끄기를 골라요. 클릭을 막지 않아요.
- 절전 모드는 어두운 화면이에요. 레서는 그대로 움직이고, 위젯도 같은 모드로 바뀌어요.

## 블록 만들기

- 걸리는 시간: − / + 로 10분씩 바꾸거나, 칸에 직접 입력 (`1:30`, `90분`, `2.5`, `3`, `1시간 30분`). 위·아래 화살표 키도 돼요.
- 복제: 블록에 마우스를 올리면 나오는 ⧉ 누르기 (같은 날 바로 뒤 빈칸에 생겨요) · ⌥(option) 누른 채 끌면 원하는 곳에 복사 · 블록 선택 후 ⌘D

## 위젯

바탕화면 우클릭 → 위젯 편집 → "한 주 쌓기"

- **한 주 판** (큰): 블록을 누르면 바로 회색 ✓ 완료 ↔ 되돌리기
- **할 일 목록**: 이번 주 할 일만 시간 없이 체크리스트로 나열 (고정 일정은 빼요). 네모를 누르면 바로 완료. 작은·가로 1×2·큰·가로 1×4 크기
- **오늘 블록**: 가로로 긴 크기는 오늘 시간을 9–12 | 13–16 | … 처럼 접어서 블록으로 보여줘요. 작은·큰 크기는 목록 (큰 크기에서 × 누르면 삭제)
- 위젯 버튼은 **앱을 열지 않고 위젯 안에서 바로** 처리돼요. 앱이 켜져 있으면 1~2초 안에 앱 화면에도 반영되고, 꺼져 있으면 다음에 열 때 반영돼요.
- 요일 이름을 누르면 그 주로 앱이 열려요. 이름 바꾸기·시간 옮기기는 앱에서 해요.

## 데이터 위치

앱과 위젯은 같은 App Group 컨테이너의 `state.json`을 공유합니다. 그룹 ID는 `Config/Signing.xcconfig`에서 설정합니다. 메뉴의 **계획 가져오기… / 계획 백업 내보내기…**로 기존 JSON을 가져오거나 백업할 수 있습니다. 이전 개인용 설치의 파일은 [이동 안내](APP_STORE.md#기존-개인용-설치에서-이동)를 참고하세요.

## 시간 설정

- 일정 배치·이동·시간 입력은 10분 단위입니다. 50분 수업을 그대로 등록할 수 있습니다. 10의 배수가 아닌 입력은 올림을 알립니다.
- 언어는 한국어/English를 선택합니다. 한국어 화면은 24시간제, 영어 화면은 AM/PM 표시를 사용합니다. 모든 언어에서 같은 24시간·일주일 일정과 10분 단위를 사용하며 시간대나 저장된 일정은 바꾸지 않습니다. 위젯에도 같은 언어를 적용합니다.
- 이전 30분 단위 저장은 v4로 변환하며 기존 날짜·시각·길이를 보존합니다.
- 출시 방향: US$2.99 일회성 앱 구매 제안. 실제 판매 가격은 App Store Connect에서 별도로 설정해야 합니다.

## 시간·이전 데이터 변환 검사

```sh
node tests/time-migration.cjs
```

새 버전은 저장 형식 v4를 사용합니다. 앱과 위젯을 함께 업데이트하세요. 이전 앱 버전은 v4 데이터를 해석하지 못하므로 업데이트 후 구버전으로 되돌아가기 전에 저장 파일을 백업하세요.
