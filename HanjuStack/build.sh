#!/bin/zsh
# Signed developer build. Register the App Group for both targets before use.
set -euo pipefail
cd "${0:A:h}"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "전체 Xcode를 설치하고 Xcode의 Command Line Tools를 선택하세요."
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen이 필요해요: brew install xcodegen"
  exit 1
fi
python3 scripts/check-config.py --signing
xcodegen generate --quiet
xcodebuild -project HanjuStack.xcodeproj -scheme HanjuStack -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
