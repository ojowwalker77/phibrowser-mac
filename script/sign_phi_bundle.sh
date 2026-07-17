#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <Lua.app> <signing identity> <entitlements plist>" >&2
  exit 2
fi

APP_PATH="$1"
SIGNING_IDENTITY="$2"
ENTITLEMENTS_PATH="$3"
PHI_FRAMEWORK="$APP_PATH/Contents/Frameworks/Phi Framework.framework"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"

[[ -d "$APP_PATH" ]] || { echo "Missing app: $APP_PATH" >&2; exit 1; }
[[ -d "$PHI_FRAMEWORK" ]] || { echo "Missing embedded Phi Framework." >&2; exit 1; }
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Missing embedded Sparkle framework." >&2; exit 1; }
[[ -f "$ENTITLEMENTS_PATH" ]] || { echo "Missing entitlements: $ENTITLEMENTS_PATH" >&2; exit 1; }

sign_macho() {
  local path="$1"
  local description
  description="$(file -b "$path")"
  [[ "$description" == *Mach-O* ]] || return 0

  if [[ "$description" == *executable* ]]; then
    codesign --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS_PATH" \
      --sign "$SIGNING_IDENTITY" "$path"
  else
    codesign --force --options runtime --timestamp \
      --sign "$SIGNING_IDENTITY" "$path"
  fi
}

# The downloaded Chromium framework contains linker-signed helper binaries.
# Sign every Mach-O first, then seal helper apps, the framework, and the host app
# from the inside out so notarization sees one consistent Developer ID chain.
while IFS= read -r -d '' file_path; do
  sign_macho "$file_path"
done < <(find "$PHI_FRAMEWORK" -type f -print0)

while IFS= read -r -d '' helper_app; do
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$SIGNING_IDENTITY" "$helper_app"
done < <(find "$PHI_FRAMEWORK" -depth -type d -name '*.app' -print0)

codesign --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" "$PHI_FRAMEWORK"

# Sparkle's SwiftPM artifact is ad-hoc signed. Preserve each helper's own
# entitlements while replacing those signatures with this app's Developer ID;
# otherwise Apple's notarization service rejects the embedded updater tools.
codesign --force --options runtime --timestamp \
  --preserve-metadata=entitlements,requirements \
  --sign "$SIGNING_IDENTITY" \
  "$SPARKLE_FRAMEWORK/Versions/Current/Autoupdate"

for sparkle_bundle in \
  "$SPARKLE_FRAMEWORK/Versions/Current/Updater.app" \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Downloader.xpc" \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Installer.xpc"; do
  codesign --force --options runtime --timestamp \
    --preserve-metadata=entitlements,requirements \
    --sign "$SIGNING_IDENTITY" "$sparkle_bundle"
done

codesign --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" "$SPARKLE_FRAMEWORK"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS_PATH" \
  --sign "$SIGNING_IDENTITY" "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
