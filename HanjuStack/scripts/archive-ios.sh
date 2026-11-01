#!/bin/zsh
# iPhone·iPad용 서명 archive를 만들어요 (업로드는 Xcode Organizer에서 직접).
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/check-config.py --signing
command -v xcodegen >/dev/null || { echo "xcodegen이 필요해요"; exit 1; }
xcodegen generate --quiet
xcodebuild -project HanjuStack.xcodeproj -scheme HanjuStackiOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/HanjuStack-iOS.xcarchive \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration archive
echo "Xcode Organizer에서 build/HanjuStack-iOS.xcarchive 를 검증(Validate)한 뒤 App Store Connect로 올리세요."
