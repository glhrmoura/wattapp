#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP=build/WattApp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/pt-BR.lproj"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/wattapp" "$APP/Contents/MacOS/WattApp"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos 15.0 "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/WattApp" "$APP/Contents/MacOS/WattApp"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun -f clang)"
(cd bridge && CGO_ENABLED=1 GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o ../build/wattapp-bridge-arm64 . \
  && CGO_ENABLED=1 GOARCH=amd64 CGO_CFLAGS="-arch x86_64" CGO_LDFLAGS="-arch x86_64" go build -trimpath -ldflags "-s -w" -o ../build/wattapp-bridge-amd64 .)
lipo -create build/wattapp-bridge-arm64 build/wattapp-bridge-amd64 -output "$APP/Contents/MacOS/wattapp-bridge"
rm -f build/wattapp-bridge-arm64 build/wattapp-bridge-amd64
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WattApp</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>CFBundleLocalizations</key><array><string>pt-BR</string></array>
  <key>CFBundleDisplayName</key><string>WattApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.glhrmoura.wattapp</string>
  <key>CFBundleExecutable</key><string>WattApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>O WattApp usa o microfone para gravar mensagens de voz.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP/Contents/MacOS/wattapp-bridge"
codesign --force --sign - "$APP"
echo "$PWD/$APP"
