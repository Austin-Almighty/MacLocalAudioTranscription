#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

# Package the finished app so the cask checksum matches the exact uploaded ZIP.
app_path=dist/LocalTranscription.app
archive_path=dist/LocalTranscription-macOS-arm64.zip
test -x "$app_path/Contents/MacOS/LocalTranscription"
codesign --verify --strict "$app_path"
# Refuse ad hoc or unnotarized builds: Gatekeeper would block them on other Macs.
if ! spctl --assess --type execute "$app_path" 2>/dev/null || ! xcrun stapler validate -q "$app_path" 2>/dev/null; then
  print -u2 "Error: $app_path is not Developer ID signed, notarized, and stapled. Sign, notarize, and staple it before packaging a release."
  exit 1
fi
test "$(lipo -archs "$app_path/Contents/MacOS/LocalTranscription")" = arm64
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
[[ "$release_version" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]]
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
archive_sha=$(shasum -a 256 "$archive_path" | cut -d ' ' -f 1)
mkdir -p Casks
cat > Casks/local-transcription.rb <<EOF
cask "local-transcription" do
  version "$release_version"
  sha256 "$archive_sha"

  url "https://github.com/Austin-Almighty/MacLocalAudioTranscription/releases/download/v#{version}/LocalTranscription-macOS-arm64.zip"
  name "Local Transcription"
  desc "On-device audio transcription using Voz"
  homepage "https://github.com/Austin-Almighty/MacLocalAudioTranscription"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "LocalTranscription.app"
end
EOF
printf 'Release archive: %s\nCask: Casks/local-transcription.rb\n' "$archive_path"
