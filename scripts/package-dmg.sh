#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/DictifyDerived}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Dictify.app"
STAGING_DIR="$(mktemp -d /tmp/DictifyDmgStage.XXXXXX)"
MOUNT_DIR=""
DIST_DIR="$ROOT_DIR/dist"
VOLUME_NAME="Dictify Installer"
DMG_PATH="$DIST_DIR/Dictify.dmg"
RW_DMG_PATH="$DIST_DIR/Dictify-rw.dmg"
BACKGROUND_PATH="$ROOT_DIR/scripts/assets/dmg-background.png"
SIGN_SCRIPT="$ROOT_DIR/scripts/sign-and-notarize.sh"
MOUNTED=0
MOUNT_DIR_CREATED=0

hide_volume_item() {
  local item_path="$1"
  [[ -e "$item_path" ]] || return 0

  chflags hidden "$item_path" 2>/dev/null || true
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a V "$item_path" 2>/dev/null || true
  fi
}

remove_transient_volume_metadata() {
  rm -rf \
    "$MOUNT_DIR/.fseventsd" \
    "$MOUNT_DIR/.Spotlight-V100" \
    "$MOUNT_DIR/.TemporaryItems" \
    "$MOUNT_DIR/.Trashes" \
    2>/dev/null || true
}

copy_without_filesystem_metadata() {
  ditto --noextattr --noqtn --noacl --nopersistRootless "$1" "$2"
}

cleanup() {
  if [[ "$MOUNTED" == "1" && -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  if [[ "$MOUNT_DIR_CREATED" == "1" && -n "$MOUNT_DIR" ]]; then
    rmdir "$MOUNT_DIR" 2>/dev/null || true
  fi
  rm -rf "$STAGING_DIR"
  rm -f "$RW_DMG_PATH"
}
trap cleanup EXIT

cd "$ROOT_DIR"

if [[ ! -f "$BACKGROUND_PATH" ]]; then
  echo "Missing DMG background: $BACKGROUND_PATH" >&2
  exit 1
fi

XCODEBUILD_ARGS=(
  -project Dictify.xcodeproj
  -scheme Dictify
  -configuration Release
  -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  # Let Xcode build unsigned; we deep-sign ourselves via sign-and-notarize.sh.
  # This keeps the signing flow identical between xcodebuild output and the DMG copy.
  XCODEBUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
else
  XCODEBUILD_ARGS+=(CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

mkdir -p "$DIST_DIR"
copy_without_filesystem_metadata "$APP_PATH" "$STAGING_DIR/Dictify.app"

# Sign + (optionally) notarize + staple the .app before it gets packaged into the DMG.
# Notarization ticket on the .app means Gatekeeper works even if the user drags the app
# out of a DMG they got by other means. The DMG itself is also notarized below.
if [[ -x "$SIGN_SCRIPT" ]]; then
  "$SIGN_SCRIPT" app "$STAGING_DIR/Dictify.app"
else
  echo "WARNING: $SIGN_SCRIPT not found or not executable — DMG contents will be unsigned." >&2
fi

ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$STAGING_DIR/.background"
copy_without_filesystem_metadata "$BACKGROUND_PATH" "$STAGING_DIR/.background/dmg-background.png"
hide_volume_item "$STAGING_DIR/.background"

STAGING_SIZE_MB="$(du -sm "$STAGING_DIR" | awk '{print $1}')"
DMG_SIZE_MB=$((STAGING_SIZE_MB + 64))

hdiutil create \
  -size "${DMG_SIZE_MB}m" \
  -fs HFS+ \
  -volname "$VOLUME_NAME" \
  -ov \
  "$RW_DMG_PATH"

MOUNT_DIR="$(mktemp -d /tmp/DictifyDmgMount.XXXXXX)"
MOUNT_DIR_CREATED=1

hdiutil attach \
  "$RW_DMG_PATH" \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$MOUNT_DIR" \
  >/dev/null
MOUNTED=1

copy_without_filesystem_metadata "$STAGING_DIR/Dictify.app" "$MOUNT_DIR/Dictify.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
copy_without_filesystem_metadata "$BACKGROUND_PATH" "$MOUNT_DIR/.background/dmg-background.png"
hide_volume_item "$MOUNT_DIR/.background"

osascript <<APPLESCRIPT
tell application "Finder"
  set dmgFolder to POSIX file "$MOUNT_DIR" as alias
  tell folder dmgFolder
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 800, 640}

    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 132
    set text size of theViewOptions to 13
    set background picture of theViewOptions to file ".background:dmg-background.png"

    set position of item "Dictify.app" of container window to {211, 244}
    set position of item "Applications" of container window to {523, 244}
    try
      set position of item ".background" of container window to {1200, 1200}
    end try
    try
      set position of item ".fseventsd" of container window to {1200, 1200}
    end try

    update without registering applications
    delay 3
    close
    delay 1
  end tell
end tell
APPLESCRIPT

hide_volume_item "$MOUNT_DIR/.background"
remove_transient_volume_metadata

# Make the DMG auto-open its window when the user double-clicks it in Finder.
# Without this, the carefully-positioned layout (app ↔ Applications folder) is
# never shown — the user just sees a mounted volume icon with no drag target.
bless --folder "$MOUNT_DIR" --openfolder "$MOUNT_DIR" 2>/dev/null || true

sync
remove_transient_volume_metadata
sync
hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0
rmdir "$MOUNT_DIR" 2>/dev/null || true
MOUNT_DIR_CREATED=0

hdiutil convert \
  "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$DMG_PATH"

# Sign + notarize + staple the final compressed DMG.
if [[ -x "$SIGN_SCRIPT" ]]; then
  "$SIGN_SCRIPT" dmg "$DMG_PATH"
else
  echo "WARNING: $SIGN_SCRIPT not found or not executable — DMG is unsigned." >&2
fi

# Emit SHA-256 alongside the DMG so release notes can publish a verifiable checksum.
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256" )

echo "Created $DMG_PATH"
echo "Checksum: $DMG_PATH.sha256"
