#!/bin/zsh
# build.sh — compile Dev Screen and assemble a self-contained .app bundle.
set -e
cd "$(dirname "$0")"

APP="Dev Screen.app"
INSTALLED="/Applications/Dev Screen.app"

echo "compiling…"
swiftc DevScreen.swift -framework ServiceManagement -framework WebKit -o DevScreen

echo "assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp DevScreen      "$APP/Contents/MacOS/DevScreen"
cp Info.plist     "$APP/Contents/Info.plist"
cp dev-screen-ctl "$APP/Contents/Resources/dev-screen-ctl"
cp AppIcon.icns   "$APP/Contents/Resources/AppIcon.icns"
cp GUIDE.html     "$APP/Contents/Resources/GUIDE.html"
chmod +x "$APP/Contents/Resources/dev-screen-ctl"
echo "done → $APP"

# optional: ./build.sh install  → quit running instance, copy into /Applications, relaunch.
if [ "$1" = "install" ]; then
  echo "quitting any running instance…"
  pkill -f "Contents/MacOS/DevScreen" 2>/dev/null && sleep 1 || true
  echo "installing to /Applications…"
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"
  mdimport "$INSTALLED" >/dev/null 2>&1 || true
  echo "launching…"
  open "$INSTALLED"
  echo "installed + running → $INSTALLED"
fi
