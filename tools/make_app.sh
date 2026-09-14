#!/bin/zsh
# Build FXMic and wrap it in an app bundle at build/FXMic.app (ad-hoc signed, menu bar only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
rc=0; out=$(swift build -c release --product FXMic 2>&1) || rc=$?
echo "$out" | grep -E "error:|Build complete" || true
[ $rc -eq 0 ] || { echo "build failed"; exit 1; }
APP="$ROOT/build/FXMic.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/FXMic" "$APP/Contents/MacOS/FXMic"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.miguel.fxmic</string>
  <key>CFBundleName</key><string>FXMic</string>
  <key>CFBundleDisplayName</key><string>FXMic</string>
  <key>CFBundleExecutable</key><string>FXMic</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>FXMic listens to the EP-2350 through the Sabrent input and transcribes on-device.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>On-device transcription of what you say into the mic.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
KC="$HOME/Library/Keychains/fxmic-signing.keychain-db"
if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "FXMic Dev"; then
  [ -f "$HOME/.fxmic/signing-keychain.pw" ] && security unlock-keychain -p "$(cat "$HOME/.fxmic/signing-keychain.pw")" "$KC" 2>/dev/null || true
  codesign --force --deep --sign "FXMic Dev" --keychain "$KC" --identifier com.miguel.fxmic "$APP" 2>&1 | grep -v "replacing existing signature" || true
  echo "signed with the stable identity: $(codesign -dv "$APP" 2>&1 | grep -E '^Authority|TeamIdentifier' | head -1)"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "ad-hoc signed (run tools/make_signing_identity.sh for a stable identity)"
fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/FXMic.app" && ditto "$APP" "$HOME/Applications/FXMic.app"
echo "built $APP and installed to ~/Applications/FXMic.app"
