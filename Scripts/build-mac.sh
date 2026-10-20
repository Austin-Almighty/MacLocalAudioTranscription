#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
xcodebuild build -project LocalTranscription.xcodeproj -scheme LocalTranscription \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS= \
  > build/macos-build.log 2>&1
ditto build/DerivedData/Build/Products/Release/LocalTranscription.app dist/LocalTranscription.app
codesign --force --sign - --timestamp=none dist/LocalTranscription.app
test -x dist/LocalTranscription.app/Contents/MacOS/LocalTranscription
codesign --verify --strict --verbose=2 dist/LocalTranscription.app
printf 'App ready: %s/dist/LocalTranscription.app\n' "$PWD"
