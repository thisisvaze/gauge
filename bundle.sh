#!/bin/sh
# ./bundle.sh          -> build/gauge.app (signed with your Apple Development cert so Full Disk Access survives rebuilds; ad-hoc if none)
# ./bundle.sh install  -> also replaces /Applications/gauge.app and relaunches it
set -e
cd "$(dirname "$0")"
# SwiftPM stamps the minimum macOS as the binary's SDK version too, and macOS picks newer behavior (like the 26 design) by that number: stamp the real SDK
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker "$(plutil -extract LSMinimumSystemVersion raw Info.plist)" -Xlinker "$(xcrun --show-sdk-version)"
APP=build/gauge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Gauge "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
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
