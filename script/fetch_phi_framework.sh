#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORK_VERSION="${1:-${PHI_FRAMEWORK_VERSION:-v2.2.0}}"
FRAMEWORK_DIR="$ROOT_DIR/Frameworks/Phi Framework.framework"
REPOSITORY="phibrowser/phibrowser-framework"
ASSET_NAME="Phi.Framework.zip"

if [[ -d "$FRAMEWORK_DIR" ]]; then
  echo "Phi Framework is already present at $FRAMEWORK_DIR"
  exit 0
fi

command -v gh >/dev/null || {
  echo "gh is required to resolve the framework release asset." >&2
  exit 1
}

asset_url="$(
  gh api "repos/$REPOSITORY/releases/tags/$FRAMEWORK_VERSION" \
    --jq ".assets[] | select(.name == \"$ASSET_NAME\") | .browser_download_url"
)"
asset_digest="$(
  gh api "repos/$REPOSITORY/releases/tags/$FRAMEWORK_VERSION" \
    --jq ".assets[] | select(.name == \"$ASSET_NAME\") | .digest"
)"

if [[ -z "$asset_url" || "$asset_digest" != sha256:* ]]; then
  echo "Could not resolve a checksummed $ASSET_NAME asset for $FRAMEWORK_VERSION." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/phi-framework.XXXXXX")"
archive_path="$work_dir/$ASSET_NAME"
extracted_dir="$work_dir/extracted"
mkdir -p "$extracted_dir" "$ROOT_DIR/Frameworks"

curl --fail --location --retry 3 --output "$archive_path" "$asset_url"

expected_digest="${asset_digest#sha256:}"
actual_digest="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [[ "$actual_digest" != "$expected_digest" ]]; then
  echo "Framework digest mismatch: expected $expected_digest, got $actual_digest." >&2
  exit 1
fi

ditto -x -k "$archive_path" "$extracted_dir"
if [[ ! -d "$extracted_dir/Phi Framework.framework" ]]; then
  echo "The framework archive did not contain Phi Framework.framework." >&2
  exit 1
fi

ditto "$extracted_dir/Phi Framework.framework" "$FRAMEWORK_DIR"
echo "Installed Phi Framework $FRAMEWORK_VERSION ($actual_digest)."
