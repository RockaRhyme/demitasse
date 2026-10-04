#!/bin/zsh
# Builds Demitasse.app, installs it in ~/Applications and launches it.
set -e
cd "$(dirname "$0")"
# Build outside the project so a synced folder (iCloud, Dropbox) can't add attributes that break signing.
B="$(mktemp -d)"
APP="$B/Demitasse.app"
mkdir -p "$APP/Contents/MacOS"
# Without an explicit target the binary only runs on the build machine's macOS or newer.
swiftc -O -target "$(uname -m)-apple-macos13.0" src/*.swift -o "$APP/Contents/MacOS/Demitasse"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Demitasse</string>
<key>CFBundleIdentifier</key><string>io.github.rockarhyme.demitasse</string>
<key>CFBundleExecutable</key><string>Demitasse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
xattr -cr "$APP"; codesign --force --sign - "$APP"
mkdir -p ~/Applications
pkill -x Demitasse 2>/dev/null || true
rm -rf ~/Applications/Demitasse.app
cp -R "$APP" ~/Applications/ && xattr -cr ~/Applications/Demitasse.app
rm -rf "$B"
open ~/Applications/Demitasse.app
