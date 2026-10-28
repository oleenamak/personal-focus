#!/bin/zsh
# Builds "Personal Focus.app" into ./build. Needs only the Xcode Command Line Tools (swiftc).
set -e
cd "$(dirname "$0")"
APP="build/Personal Focus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O Sources/Core/*.swift Sources/App/main.swift -o "$APP/Contents/MacOS/PersonalFocus" \
  -framework AppKit -framework WebKit
cp ui/index.html "$APP/Contents/Resources/index.html"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Personal Focus</string>
  <key>CFBundleIdentifier</key><string>local.personal-focus</string>
  <key>CFBundleExecutable</key><string>PersonalFocus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $PWD/$APP"
