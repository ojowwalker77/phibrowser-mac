#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.derivedData-performance"
FRAMEWORK_INFO="$ROOT_DIR/Frameworks/Phi Framework.framework/Resources/Info.plist"
REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"

"$ROOT_DIR/script/fetch_phi_framework.sh"
FRAMEWORK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FRAMEWORK_INFO")"

echo "Performance build: revision=$REVISION framework=$FRAMEWORK_VERSION"
xcodebuild \
  -quiet \
  -project "$ROOT_DIR/Phi.xcodeproj" \
  -scheme PhiBrowser-Performance \
  -configuration Performance \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  PHI_BUILD_REVISION="$REVISION" \
  PHI_FRAMEWORK_VERSION="$FRAMEWORK_VERSION" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

echo "Performance app: $DERIVED_DATA/Build/Products/Performance/Phi.app"
