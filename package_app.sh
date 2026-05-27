#!/bin/bash
set -e

APP_NAME="WisprWave"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "🚀 Building ${APP_NAME} for release..."
swift build -c release

echo "📦 Creating App Bundle structure..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "📋 Copying executable..."
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "📝 Generating Info.plist..."
cat <<EOF > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.panks.${APP_NAME}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/> <!-- Hides from Dock -->
    <key>NSMicrophoneUsageDescription</key>
    <string>This app needs microphone access to transcribe your speech.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>This app needs speech recognition to convert your voice to text.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

echo "📥 Copying Resources..."
# Create Resources directory if it doesn't exist
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Check for AppIcon.icns in Sources/WisprWave/Resources/
if [ -f "Sources/WisprWave/Resources/AppIcon.icns" ]; then
    echo "   Found AppIcon.icns, copying..."
    cp "Sources/WisprWave/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
else
    echo "⚠️  Warning: Sources/WisprWave/Resources/AppIcon.icns not found."
    echo "   The app will have the default system icon."
fi



echo "� Generating Entitlements.plist..."
cat <<EOF > "Entitlements.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
EOF

# Choose a signing identity. A stable (self-signed) identity keeps the app's
# "designated requirement" constant across rebuilds, so macOS preserves the
# Accessibility permission after every update. Ad-hoc signing does NOT — its identity
# is the binary's content hash, which changes every build, forcing a re-grant.
#
# Order: explicit WISPRWAVE_SIGN_ID env var > "WisprWave Local Signing" cert > ad-hoc.
# Create the stable cert once with ./create_signing_cert.sh
SIGN_NAME="WisprWave Local Signing"
if [ -n "${WISPRWAVE_SIGN_ID:-}" ]; then
    SIGN_ID="${WISPRWAVE_SIGN_ID}"
    echo "🔑 Signing with identity from WISPRWAVE_SIGN_ID: ${SIGN_ID}"
elif security find-identity -p codesigning | grep -q "${SIGN_NAME}"; then
    SIGN_ID="${SIGN_NAME}"
    echo "🔑 Signing with stable identity '${SIGN_NAME}' (Accessibility grant will persist across updates)."
else
    SIGN_ID="-"
    echo "⚠️  No stable signing identity found — falling back to ad-hoc signing."
    echo "    The Accessibility permission will need re-granting after each update."
    echo "    Run ./create_signing_cert.sh once to fix this permanently."
fi

codesign --force --deep --entitlements "Entitlements.plist" --sign "${SIGN_ID}" "${APP_BUNDLE}"
rm "Entitlements.plist"

echo "✅ App Bundle created at ${APP_BUNDLE}"
echo "🎉 You can now zip this app and share it!"
echo "   Run: zip -r ${APP_NAME}.zip ${APP_BUNDLE}"
