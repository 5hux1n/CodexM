#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/Verification dist
python3 scripts/validate_resources.py
xcodebuild -project CodexM.xcodeproj -scheme CodexM -configuration Release \
  -derivedDataPath build/ReleaseDerivedData -destination 'generic/platform=macOS' \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- clean build \
  > build/Verification/release-build.log 2>&1
# Stage into a fresh directory before replacing an earlier generated delivery.
release_stage=$(mktemp -d "$PWD/build/delivery.XXXXXX")
ditto build/ReleaseDerivedData/Build/Products/Release/CodexM.app "$release_stage/CodexM.app"
codesign --verify --deep --strict "$release_stage/CodexM.app"
# ditto updates a prior app safely; this target only contains generated outputs.
ditto "$release_stage/CodexM.app" dist/CodexM.app
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/CodexM.app/Contents/Info.plist)
archive="dist/CodexM-v${version}-macOS.zip"
disk_image="dist/CodexM-v${version}-macOS.dmg"
ditto -c -k --sequesterRsrc --keepParent dist/CodexM.app "$archive"
ln -s /Applications "$release_stage/Applications"
hdiutil create -volname "CodexM ${version}" -srcfolder "$release_stage" -ov -format UDZO "$disk_image"
hdiutil verify "$disk_image"
(cd dist && shasum -a 256 "${disk_image:t}" "${archive:t}" > SHA256SUMS.txt)
lipo -info dist/CodexM.app/Contents/MacOS/CodexM
printf '%s\n' 'Release ready: dist/CodexM.app'
