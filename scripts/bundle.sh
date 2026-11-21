#!/bin/bash
# Builds release binaries and assembles dist/AIStats.app (ad-hoc signed).
# Uses eyebuild when it is installed (build caches off the internal disk), else plain `swift build`.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
if command -v eyebuild >/dev/null 2>&1; then SWIFT=(eyebuild swift release --); else SWIFT=(swift); fi
"${SWIFT[@]}" build -c release --product AIStatsMenu
"${SWIFT[@]}" build -c release --product aistats
BIN=$("${SWIFT[@]}" build -c release --show-bin-path | tail -1)

APP="$ROOT/dist/AIStats.app"
# Assemble next to the old app, then swap it in with one rename: agents registered with
# dist/AIStats.app/Contents/MacOS/aistats never find the binary missing mid-build.
STAGE="$ROOT/dist/.AIStats.app.new"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN/AIStatsMenu" "$STAGE/Contents/MacOS/AIStatsMenu"
cp "$BIN/aistats" "$STAGE/Contents/MacOS/aistats"
FONT_BUNDLE="$BIN/AIStats_AIStatsMenu.bundle"
FONT_DIR="$FONT_BUNDLE/Contents/Resources/Fonts"
if [ ! -d "$FONT_DIR" ]; then FONT_DIR="$FONT_BUNDLE/Fonts"; fi
for file in Orbitron-{Black,Bold}.ttf JetBrainsMono-{Regular,Bold}.ttf {Orbitron,JetBrainsMono}-OFL.txt NOTICE.md; do
  if [ ! -s "$FONT_DIR/$file" ]; then
    echo "Missing font resource: $FONT_DIR/$file" >&2
    exit 1
  fi
done
cp -R "$FONT_BUNDLE" "$STAGE/Contents/Resources/"
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
