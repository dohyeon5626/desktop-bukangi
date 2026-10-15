#!/bin/zsh
# Builds build/Bukangi.app from the Swift package.
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Bukangi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Bukangi "$APP/Contents/MacOS/Bukangi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
