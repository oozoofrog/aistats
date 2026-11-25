#!/bin/bash
# Build in a temporary directory and atomically install the signed app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$PWD" == /Volumes/eyedisk/* || -d /Volumes/eyedisk ]]; then
  [[ "$(stat -f %d /Volumes/eyedisk)" != "$(stat -f %d /Volumes)" ]] || exit 1
  export TMPDIR=/Volumes/eyedisk/tmp
  BUILD_ROOT=/Volumes/eyedisk/build/aistats
else
  BUILD_ROOT="${TMPDIR:-/tmp}"
fi
mkdir -p "$BUILD_ROOT"
BUILD=$(mktemp -d "$BUILD_ROOT/install.XXXXXX")
INSTALL_STAGE=""
cleanup() {
  rm -rf "$BUILD"
  if [[ -n "$INSTALL_STAGE" ]]; then rm -rf "$INSTALL_STAGE"; fi
}
trap cleanup EXIT
SWIFT=(swift build --scratch-path "$BUILD" -c release)
"${SWIFT[@]}" --product AIStatsMenu
"${SWIFT[@]}" --product aistats
BIN=$("${SWIFT[@]}" --show-bin-path)

APP=/Applications/AIStats.app
INSTALL_STAGE=$(mktemp -d /Applications/.aistats-install.XXXXXX)
STAGE="$INSTALL_STAGE/AIStats.app"
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
IDENTITY="${AISTATS_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$STAGE/Contents/MacOS/aistats"
codesign --force --sign "$IDENTITY" "$STAGE"
codesign --verify --strict "$STAGE"
if [ -d "$APP" ]; then
  # Atomic exchange of the two bundles (running processes keep their open binaries).
  python3 -c "import ctypes,sys; l=ctypes.CDLL(None); sys.exit(0 if l.renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), 2)==0 else 1)" "$STAGE" "$APP"
  rm -rf "$STAGE"
else
  mv "$STAGE" "$APP"
fi
echo "$APP"
