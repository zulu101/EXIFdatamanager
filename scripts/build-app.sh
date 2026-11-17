#!/usr/bin/env bash
# Baut „EXIF Data Manager.app“ im Ordner build/.
# Voraussetzung: macOS 14+ mit Xcode bzw. den Xcode Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="EXIF Data Manager"
EXECUTABLE="ExifDataManager"
BUNDLE_ID="de.exifdatamanager.app"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "▸ Kompiliere (Release) …"
swift build -c release --product "$EXECUTABLE"
BIN_PATH="$(swift build -c release --product "$EXECUTABLE" --show-bin-path)/$EXECUTABLE"

echo "▸ Erzeuge App-Bundle …"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$EXECUTABLE"

echo "▸ Erzeuge App-Icon …"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>de</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ Signiere (ad hoc) …"
codesign --force --deep --sign - "$APP_DIR"

echo "▸ Erstelle ZIP …"
(cd "$BUILD_DIR" && rm -f "$APP_NAME.zip" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")

echo "✓ Fertig: $APP_DIR"
