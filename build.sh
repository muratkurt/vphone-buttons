#!/bin/sh
# Builds "VPhone Buttons.app" (Apple silicon) and VPhone-Buttons.zip into build/.
# The bundle is assembled and signed in a temporary folder: synced folders
# (Desktop, Documents in iCloud) add attributes codesign refuses.
set -eu
cd "$(dirname "$0")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/VPhone Buttons.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 App/Sources/*.swift -o "$APP/Contents/MacOS/VPhoneButtons"
cp App/Info.plist "$APP/Contents/"
cp App/Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R App/Resources/*.lproj "$APP/Contents/Resources/"
xattr -cr "$APP"
codesign --force --sign - "$APP"
(cd "$WORK" && ditto -c -k --keepParent "VPhone Buttons.app" "VPhone-Buttons.zip")
rm -rf build && mkdir build
ditto "$APP" "build/VPhone Buttons.app"
cp "$WORK/VPhone-Buttons.zip" build/
echo "built build/VPhone Buttons.app and build/VPhone-Buttons.zip"
