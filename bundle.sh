#!/bin/sh
# ./bundle.sh          -> build/Gauge.app (signed with your Apple Development cert so Full Disk Access survives rebuilds; ad-hoc if none)
# ./bundle.sh install  -> also replaces /Applications/Gauge.app and relaunches it
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Gauge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Gauge "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
ID=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
if [ "$1" = install ]; then
  pkill -x Gauge || true
  rm -rf /Applications/Gauge.app
  cp -R "$APP" /Applications/
  open /Applications/Gauge.app
  echo "/Applications/Gauge.app"
else
  echo "$APP"
fi
