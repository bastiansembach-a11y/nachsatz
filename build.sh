#!/bin/zsh
# Builds Nachsatz.app in this folder. Needs only the Xcode Command Line Tools.
#
#   ./build.sh
#   SIGN_ID="Apple Development: …" ./build.sh   sign with your own identity (keeps the Accessibility grant across rebuilds)
#   BUNDLE_ID=local.nachsatz.dev ./build.sh     use another bundle identifier
set -e
cd "${0:A:h}"
BUNDLE_ID=${BUNDLE_ID:-local.nachsatz.app}
SIGN_ID=${SIGN_ID:--}
VERSION=$(<VERSION)
APP=Nachsatz.app

swift build -c release --product Nachsatz
BIN=$(swift build -c release --show-bin-path)/Nachsatz

rm -rf Nachsatz.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/Nachsatz.icns "$APP/Contents/Resources/"
cp "$BIN" "$APP/Contents/MacOS/Nachsatz"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleIconFile</key><string>Nachsatz</string>
<key>CFBundleName</key><string>Nachsatz</string>
<key>CFBundleExecutable</key><string>Nachsatz</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleDevelopmentRegion</key><string>de</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
plutil -lint -s "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $PWD/$APP ($BUNDLE_ID, $VERSION)"
