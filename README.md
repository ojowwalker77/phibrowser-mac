# Phi Browser

**A local-first, native Chromium browser for macOS.**

This fork of Phi is built as a real macOS app with AppKit, SwiftUI, and an embedded Chromium framework. It starts without an account, keeps browser state locally, and focuses on the core browsing experience.

> **Download** (free, macOS): [phibrowser.com](https://phibrowser.com) · If this is your kind of thing, a ⭐ helps a lot.

<!-- TODO (Alpha): drop a screenshot or short demo gif here. It roughly triples how many visitors star. -->

## What it includes

- **No required account.** Launch directly into the browser with a local profile.
- **Focused first run.** Choose a layout, import data from another browser, and configure password-manager support.
- **Native macOS interface.** AppKit and SwiftUI provide windows, sidebars, settings, and system integration.
- **Chromium compatibility.** Tabs, profiles, extensions, downloads, bookmarks, history, and developer tools use the embedded Chromium framework.
- **Spaces and layouts.** Organize tabs into Spaces and choose the density that fits your workflow.
- **No AI feature layer.** Chat, agents, browser memory, connectors, AI tab organization, and their background services are not part of this fork.

## Why open source

A browser sees everything you do, so you should be able to read the code that runs it. The macOS client is Apache-2.0 and the Chromium framework layer lives separately.

## Download

Free for macOS on Apple Silicon: [phibrowser.com](https://phibrowser.com)

## Build from source

### Requirements
- Mac with Apple chip
- Xcode 26+
- A local copy of `Phi Framework.framework`

### Steps
1. Check out this repository.
2. Download the latest `Phi Framework` from [phibrowser/phibrowser-framework](https://github.com/phibrowser/phibrowser-framework/releases).
3. Place `Phi Framework.framework` into the root `Frameworks/` directory.
4. Open `Phi.xcodeproj` in Xcode and let Swift Package Manager resolve dependencies.
5. Select the `PhiBrowser-OpenSource` scheme.
6. Build.

For this fork, `./script/build_and_run.sh --verify` downloads and verifies the
framework when needed, builds the app, launches it, and confirms that the
process started. Signed and notarized releases are documented in
[`RELEASING.md`](RELEASING.md).

### Development profile

The `PhiBrowser-OpenSource` configuration intentionally uses the installed
Phi app's `com.phibrowser.Mac` data directory. Local builds therefore have the
same profiles, cookies, history, tabs, and Spaces as the DMG build. The run
script quits any running Phi process immediately before launching the local
app because Chromium profiles must never have two writers. Quit the local build
before reopening `/Applications/Phi.app`.

The distributable `Release` configuration remains isolated under the fork's
`com.ojowwalker77.PhiBrowser` identifier. Passwords or passkeys protected by
the upstream Developer ID may still be unavailable to an ad-hoc local build.

## Contributing

Contributions are welcome. Found a bug, have an idea, or want to add a feature? Open an issue first. To contribute code, send a PR with a clear description of the change and the motivation behind it.

We welcome bug reports, feature requests, documentation improvements, and pull requests.

## License

Apache License 2.0. See [LICENSE](LICENSE).
