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
if [ ! -f build/AppIcon.icns ] || [ docs/logo.svg -nt build/AppIcon.icns ]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift -e '
    import AppKit
    let img = NSImage(contentsOf: URL(fileURLWithPath: "docs/logo.svg"))!
    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
      NSGraphicsContext.restoreGraphicsState()
      try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/AppIcon.iconset/icon_\(name).png"))
    }
  '
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
  rm -rf "$ICONSET"
fi
APP=build/gauge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(build --show-bin-path)/Gauge" "$APP/Contents/MacOS/"
strip -x "$APP/Contents/MacOS/Gauge"  # local symbols are half the binary and nothing reads them
cp build/AppIcon.icns "$APP/Contents/Resources/"
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
