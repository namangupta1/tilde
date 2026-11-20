#!/usr/bin/env bash
# Builds Tilde.app (release) and packages it into dist/Tilde-<version>.dmg
#
# Signing:
#   default                     ad-hoc signature (runs on this Mac; others must right-click ▸ Open)
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
#                               signs with hardened runtime for distribution
#   NOTARY_PROFILE=profile      also notarizes + staples (create the profile once with
#                               xcrun notarytool store-credentials profile --apple-id … --team-id …)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tilde"
BUNDLE_ID="app.tilde.terminal"
VERSION="${VERSION:-0.1.0}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "→ Building release binary"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BINDIR=".build/apple/Products/Release"
else
  echo "  (universal build unavailable, building for host arch)"
  swift build -c release
  BINDIR=".build/release"
fi

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BINDIR/tilde-session" "$APP/Contents/MacOS/tilde-session"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "→ Signing with $DEVELOPER_ID (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP/Contents/MacOS/tilde-session"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "→ Ad-hoc signing (set DEVELOPER_ID to sign for distribution)"
  codesign --force --sign - "$APP/Contents/MacOS/tilde-session"
  codesign --force --sign - "$APP"
fi

echo "→ Creating DMG"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "→ Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
  fi
fi

echo "✓ $APP"
echo "✓ $DMG"
