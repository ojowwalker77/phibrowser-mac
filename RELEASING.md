# Lua Browser releases

Lua ships Apple Silicon ZIP and DMG artifacts as
`Lua-Browser-<version>-arm64`. Public artifacts must be Developer ID signed,
notarized, stapled, Gatekeeper-assessed, checksummed, and published with a
signed Sparkle appcast. The DMG must contain both `Lua.app` and an
`Applications` symlink so installation is an ordinary drag-and-drop flow. The
release workflow mounts the generated DMG and verifies that layout before
notarization. There is no unsigned public-release fallback.

## Publish a version

1. Prepare version metadata and release notes in a pull request.
2. Merge to `main` after the required `Quality` check passes.
3. Run `./script/release-preflight X.Y.Z` on the clean release commit.
4. Create and push the immutable tag `vX.Y.Z`.
5. Verify the Release workflow and its published checksums.

Manual dispatch can retry an existing version, but cannot create a release
from a dirty or unverified source state.

## Required repository secrets

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_API_KEY_P8`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`

For the first Lua release, the workflow also accepts the existing legacy
aliases `MACOS_CERTIFICATE_P12`, `APPLE_API_KEY`, and `APPLE_API_ISSUER`.
Migrate those values to the preferred names above before removing the aliases.

## Required repository variables

- `APPLE_TEAM_ID`

`PHI_FRAMEWORK_VERSION` remains an optional repository variable. Any version
other than the repository default also requires `PHI_FRAMEWORK_SHA256` and
may use `PHI_FRAMEWORK_URL`. The release refuses an unpinned framework.

## External framework boundary

The build currently downloads `Phi Framework.framework` from the upstream
`phibrowser/phibrowser-framework` release because no authorized
owner-controlled distribution has been established. The repository pins and
verifies the exact SHA-256, but that does not make the dependency independent.
Do not mirror or redistribute it without confirmed rights.

The same framework currently embeds an upstream Sentry Crashpad minidump URL,
upstream feedback/help URLs, and Phi product annotations. Lua passes
`--disable-crash-reporter`, but its effect on this prebuilt framework has not
been runtime-verified. Release validation
audits these against `script/framework-endpoint-allowlist.txt` and fails on new
entries, but the known entries remain a privacy blocker. Every release and PR
must disclose this boundary until the framework is rebuilt under Lua's control.
