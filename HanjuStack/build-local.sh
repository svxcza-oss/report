#!/bin/zsh
# 개인용 빌드: 개발자 계정 없이 내 맥에서 바로 쓰는 버전 (애드혹 서명).
# 앱스토어용 서명 빌드는 ./build.sh 를 써요.
set -euo pipefail
cd "${0:A:h}"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode가 필요해요. App Store에서 Xcode 설치 → 한 번 실행 → 아래 명령 후 다시 시도:"
  echo "  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen이 필요해요:  brew install xcodegen"; exit 1; }
mkdir -p Generated
xcodegen generate --spec project.local.yml --quiet
xcodebuild -project HanjuStackLocal.xcodeproj -target HanjuStack -configuration Release \
  SYMROOT="$PWD/build/local" ONLY_ACTIVE_ARCH=YES -quiet
echo "완료: $PWD/build/local/Release/HanjuStack.app"
