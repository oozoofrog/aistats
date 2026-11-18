#!/bin/bash
# Builds release binaries with eyebuild and assembles dist/AIStats.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
eyebuild swift release -- build -c release --product AIStatsMenu
eyebuild swift release -- build -c release --product aistats
BIN=$(eyebuild swift release -- build -c release --show-bin-path | tail -1)

APP="$ROOT/dist/AIStats.app"
# Assemble next to the old app, then swap it in with one rename: agents registered with
# dist/AIStats.app/Contents/MacOS/aistats never find the binary missing mid-build.
STAGE="$ROOT/dist/.AIStats.app.new"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN/AIStatsMenu" "$STAGE/Contents/MacOS/AIStatsMenu"
cp "$BIN/aistats" "$STAGE/Contents/MacOS/aistats"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$STAGE/Contents/MacOS/aistats"
codesign --force --sign - "$STAGE"
codesign --verify --strict "$STAGE"
if [ -d "$APP" ]; then
  # Atomic exchange of the two bundles (running processes keep their open binaries).
  python3 -c "import ctypes,sys; l=ctypes.CDLL(None); sys.exit(0 if l.renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), 2)==0 else 1)" "$STAGE" "$APP"
  rm -rf "$STAGE"
else
  mv "$STAGE" "$APP"
fi
echo "$APP"
