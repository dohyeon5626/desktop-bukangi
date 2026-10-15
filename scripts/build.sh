#!/bin/zsh
# Builds build/Bukangi.app from the Swift package.
#
#   scripts/build.sh                 # build for this Mac
#   scripts/build.sh --universal     # arm64 + x86_64
#   VERSION=1.2.0 scripts/build.sh   # stamp the app version (defaults to Info.plist's)
#   scripts/build.sh --zip           # also write build/Bukangi-<version>.zip
set -e
cd "$(dirname "$0")/.."

universal=false
zip=false
for arg in "$@"; do
  case "$arg" in
    --universal) universal=true ;;
    --zip) zip=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if $universal; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Bukangi
else
  swift build -c release
  BIN=.build/release/Bukangi
fi

APP=build/Bukangi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bukangi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

if $zip; then
  version=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
  ZIP="build/Bukangi-$version.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Packed $ZIP"
fi
