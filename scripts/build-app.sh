#!/bin/bash
# Builds ECMDecoder.app (universal: Apple silicon and Intel) and packages it
# as a DMG. Requires macOS with Xcode or the Command Line Tools.
#
#   scripts/build-app.sh 1.0.0
#
# Output: build/ECMDecoder.app and build/ECMDecoder-<version>.dmg
set -euo pipefail

VERSION="${1:?usage: scripts/build-app.sh <version>}"
APP_NAME="ECMDecoder"
BUNDLE_ID="io.github.victor-r-dejesus.ECMDecoder"
MIN_MACOS="12.0"

cd "$(dirname "$0")/.."
BUILD="build"
APP="$BUILD/$APP_NAME.app"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"

rm -rf "$APP" "$DMG" "$BUILD/dmg"
mkdir -p "$APP/Contents/MacOS" "$BUILD/dmg"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=(App/*.swift Sources/ECMDecoderCore/*.swift)

for ARCH in arm64 x86_64; do
  echo "Compiling for $ARCH..."
  xcrun swiftc -O -parse-as-library \
    -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" \
    "${SOURCES[@]}" -o "$BUILD/$APP_NAME-$ARCH"
done
lipo -create "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64" \
  -output "$APP/Contents/MacOS/$APP_NAME"
rm "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: required to run on Apple silicon. It is not a Developer ID
# signature, so Gatekeeper asks the user to confirm the first launch.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose "$APP"

cp -R "$APP" "$BUILD/dmg/"
ln -s /Applications "$BUILD/dmg/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$BUILD/dmg" \
  -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$BUILD/dmg"

echo "Built $DMG"
