#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORK_VERSION="${1:-${PHI_FRAMEWORK_VERSION:-v2.2.0}}"
FRAMEWORK_DIR="$ROOT_DIR/Frameworks/Phi Framework.framework"
REPOSITORY="phibrowser/phibrowser-framework"
ASSET_NAME="Phi.Framework.zip"
DEFAULT_VERSION="v2.2.0"
DEFAULT_SHA256="19fc1f816b5dc19237e4ed41c3bcf63fc50650702d53ceb250d0088dcfa67fd1"

if [[ -d "$FRAMEWORK_DIR" ]]; then
  echo "Phi Framework is already present at $FRAMEWORK_DIR"
  exit 0
fi

if [[ "$FRAMEWORK_VERSION" == "$DEFAULT_VERSION" ]]; then
  expected_digest="${PHI_FRAMEWORK_SHA256:-$DEFAULT_SHA256}"
else
  expected_digest="${PHI_FRAMEWORK_SHA256:-}"
fi
asset_url="${PHI_FRAMEWORK_URL:-https://github.com/$REPOSITORY/releases/download/$FRAMEWORK_VERSION/$ASSET_NAME}"

if [[ ! "$expected_digest" =~ ^[0-9a-f]{64}$ ]]; then
  echo "PHI_FRAMEWORK_SHA256 is required for non-default framework versions." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/phi-framework.XXXXXX")"
archive_path="$work_dir/$ASSET_NAME"
extracted_dir="$work_dir/extracted"
mkdir -p "$extracted_dir" "$ROOT_DIR/Frameworks"

curl --fail --location --retry 3 --output "$archive_path" "$asset_url"

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
