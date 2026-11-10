#!/bin/sh
# ./bundle.sh          -> build/gauge.app (signed with your Apple Development cert so Full Disk Access survives rebuilds; ad-hoc if none)
# ./bundle.sh install  -> also replaces /Applications/gauge.app and relaunches it
# ./bundle.sh release  -> build/gauge.zip: Apple silicon + Intel, signed with your Developer ID (ad-hoc if none).
#                         NOTARY_PROFILE=<name from `xcrun notarytool store-credentials`> ./bundle.sh release also notarizes it.
set -e
cd "$(dirname "$0")"
ARCH=""
if [ "$1" = release ]; then ARCH="--arch arm64 --arch x86_64"; fi
# SwiftPM stamps the minimum macOS as the binary's SDK version too, and macOS picks newer behavior (like the 26 design) by that number: stamp the real SDK
build() { swift build -c release $ARCH -Xlinker -platform_version -Xlinker macos -Xlinker "$(plutil -extract LSMinimumSystemVersion raw Info.plist)" -Xlinker "$(xcrun --show-sdk-version)" "$@"; }
build
APP=build/gauge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(build --show-bin-path)/Gauge" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
if [ "$1" = release ]; then
  ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
  if [ -n "$ID" ]; then codesign --force --options runtime --timestamp --sign "$ID" "$APP"; else codesign --force --sign - "$APP"; fi
  rm -f build/gauge.zip
  ditto -c -k --keepParent "$APP" build/gauge.zip
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit build/gauge.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm build/gauge.zip
    ditto -c -k --keepParent "$APP" build/gauge.zip  # again, now with the notarization ticket inside
  fi
  echo build/gauge.zip
  exit
fi
ID=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
if [ "$1" = install ]; then
  pkill -x Gauge || true
  rm -rf /Applications/gauge.app
  cp -R "$APP" /Applications/
  open /Applications/gauge.app
  echo "/Applications/gauge.app"
else
  echo "$APP"
fi
