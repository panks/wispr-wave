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

echo "📝 Generating Info.plist..."
cat <<EOF > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.pankaj.${APP_NAME}</string>
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

echo "✅ App Bundle created at ${APP_BUNDLE}"
echo "🎉 You can now zip this app and share it!"
echo "   Run: zip -r ${APP_NAME}.zip ${APP_BUNDLE}"
