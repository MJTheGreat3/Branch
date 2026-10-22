#!/bin/sh
# Builds Branch and wraps it in a signed .app bundle at build/Branch.app.
set -eu

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Branch.app"
BUNDLE_ID="${BUNDLE_ID:-com.branch.app}"
VERSION="${VERSION:-0.1.0}"
SIGN_ID="${SIGN_ID:--}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Branch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Branch"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Branch</string>
    <key>CFBundleDisplayName</key><string>Branch</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Branch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Branch Stand-in</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>${BUNDLE_ID}.stand-in</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>${BUNDLE_ID}.stand-in</string>
            <key>UTTypeDescription</key><string>Branch Stand-in (file in OneDrive only)</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key><array><string>branch</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
echo "Built $APP"
