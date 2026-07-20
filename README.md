# Lua Browser

**A calm, local-first Chromium browser built as a native macOS app.**

Lua combines an AppKit and SwiftUI interface with an embedded Chromium
framework. It starts without an account, keeps browser state local, and
focuses on the core browsing experience.

## What it includes

- No required account
- Native macOS windows, sidebars, settings, and system integration
- Chromium tabs, profiles, extensions, downloads, bookmarks, and DevTools
- Spaces for organizing tabs and profiles
- Built-in local tracking-parameter protection with Remove and Mask modes
- An optional local CDP skill for supervised browser automation

Inherited Phi account, connector, rollback, crash-help, and update services
are intentionally disconnected. Account and connector calls are disabled by
default; development endpoints must be supplied explicitly with
`LUA_ACCOUNT_BASE_URL` and `LUA_CONNECTOR_BASE_URL`. Until Lua owns compatible
services, those account-backed surfaces should be treated as unavailable.

## Build from source

Requirements: Apple Silicon Mac, Xcode 26 or newer, GitHub CLI, and access to
the pinned `Phi Framework.framework` release.

```bash
./script/bootstrap
./script/run
```

The shared repository commands are:

- `./script/bootstrap` — fetch and verify the pinned framework dependency
- `./script/run` — build and launch Lua
- `./script/check` — compile the app-hosted unit suite without launching Lua
- `./script/verify` — build Release and validate the app bundle
- `./script/release-preflight X.Y.Z` — validate release identity and inputs

## Framework boundary

Lua's native client is Apache-2.0, but it still requires the separately
distributed prebuilt `Phi Framework.framework`. Version `v2.2.0` and its
SHA-256 are pinned in `script/fetch_phi_framework.sh`. The framework name,
bridge types, and `PhiAgentSpace` protocol are binary ABI names, not product
branding.

The framework is currently downloaded from
`phibrowser/phibrowser-framework`. Lua does not redistribute or mirror that
binary because redistribution rights have not been confirmed. This is an
explicit external supply-chain dependency; the project does not claim full
upstream independence until an authorized owner-controlled build exists.

The existing XCTest bundle is hosted inside the Chromium application. The
prebuilt host currently exits before XCTest connects on headless runners, so
the required `check` gate uses `build-for-testing`: all test code must compile,
but the app is not launched. Hosted test execution remains a framework blocker
rather than an unreliable required check.

### Privacy blocker in the embedded framework

The pinned framework binary also embeds an upstream Sentry Crashpad minidump
upload URL, upstream help/feedback URLs, and Phi product annotations. Lua
passes Chromium's `--disable-crash-reporter` switch as a source-owned
mitigation, but that has not been runtime-verified against this prebuilt
framework. Therefore a crash may still attempt traffic to upstream
infrastructure even though Lua's source-owned account, rollback, crash-help,
and updater endpoints have been removed. This remains an unresolved privacy
and operational dependency.

`script/framework-endpoint-allowlist.txt` records the exact audited strings;
release smoke fails if the binary adds another upstream endpoint. The allowlist
is disclosure, not approval. Lua cannot claim complete upstream independence
until the framework can be rebuilt with owner-controlled crash reporting or
crash uploads disabled.

## Identity migration

The app is displayed as **Lua** and uses `dev.jow.LuaBrowser`. Release builds
temporarily keep Chromium data in the previous fork profile directory,
`com.ojowwalker77.PhiBrowser`, so an update does not strand tabs, profiles,
cookies, or history. Debug, development, Canary, Performance, and test builds
use isolated Lua profile directories and must never touch the release profile.
The old `phi://` URL scheme remains accepted temporarily alongside canonical
`lua://` links. macOS permissions and keychain items tied to the former bundle
identifier may require reapproval.

## Tracking protection

Lua bundles a local Chromium extension that recognizes common advertising and
email attribution parameters such as `gclid`, `fbclid`, `msclkid`, and
`utm_*`. Remove mode strips them; Mask mode retains the parameter names while
replacing their values. The extension can be paused and keeps a per-profile
counter in Chromium extension storage. It has no server, account, or telemetry.
The feature was inspired by the public
[`donttrackme`](https://github.com/kiwi-init/donttrackme) project and was
implemented for Chromium as source-owned Lua code.

Followed links are cleaned before their destination navigation. When a tracked
URL is pasted, opened externally, or reached through a redirect, the initial
request may already contain its parameters; Lua then cleans the visible URL in
place. This is URL hygiene, not a network request blocker or a substitute for
engine-level anti-fingerprinting.

## Contributing and releases

Open pull requests against `main`. Releases are immutable `vX.Y.Z` tags from
commits that passed the required `Quality` check. See
[`RELEASING.md`](RELEASING.md) for signing and notarization requirements.

## License and attribution

Apache License 2.0. See [`LICENSE`](LICENSE). Existing copyright notices,
third-party credits, and framework ABI names are intentionally preserved.
