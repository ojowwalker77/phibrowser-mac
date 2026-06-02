// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import AppKit

class ExtensionManager: ObservableObject {
    struct BadgeState: Equatable {
        var text: String
        var backgroundColor: NSColor
        var textColor: NSColor
        var visible: Bool
        var enabled: Bool
    }

    @Published var extensions: [Extension] = []
    @Published var pinedExtensions: [Extension] = []
    @Published var phiExtensionVersions: [String: String] = [:]
    @Published var shouldDisplayExtensionsWithinSidebar: Bool = false
    // Per-extension action state for this window (the manager is per-window).
    @Published var badges: [String: BadgeState] = [:]
    @Published var dynamicIcons: [String: NSImage] = [:]
    private weak var browserState: BrowserState?
    init(browserState: BrowserState) {
        self.browserState = browserState
    }
    static let phiExtensionIds = ["pjlnhbfabokjejbhmgghmjiaknfhnima",
                                  "pjgdkljlcbjgedgeppodjijjphfcplno",
                                  "fenmfiepnpdlhplemgijlimpbebebljo",
                                  "ickhcgejficcoofnjnnobadfdnfbilnm"]
    
    func extensionChanged(_ info: [[String: Any]]) {
        let mapped = info.compactMap { Extension(from: $0) }
        phiExtensionVersions = Dictionary(uniqueKeysWithValues: mapped
            .filter { Self.phiExtensionIds.contains($0.id) }
            .map { ($0.name, $0.version) }
        )
        
        extensions = mapped
        #if NIGHTLY_BUILD || DEBUG
            .filter { $0.id != "fenmfiepnpdlhplemgijlimpbebebljo" }
        #else
            .filter { !Self.phiExtensionIds.contains($0.id) }
        #endif
            .sorted {
                if $0.isPinned != $1.isPinned {
                    return $0.isPinned && !$1.isPinned
                }
                if $0.isPinned && $1.isPinned {
                    return $0.pinnedIndex < $1.pinnedIndex
                }
                return $0.name < $1.name
            }
        pinedExtensions = extensions.filter { $0.isPinned }.sorted { $0.pinnedIndex < $1.pinnedIndex }

        // Reconcile per-extension action state with the current list: drop
        // badges / dynamic icons for ids Chromium no longer reports (unloaded,
        // or filtered out — e.g. incognito-ineligible), so a stale overflow dot
        // or leftover dynamic icon can't persist. Keyed off the unfiltered set
        // (`mapped`) so Phi's own built-ins aren't pruned.
        let liveIds = Set(mapped.map(\.id))
        let prunedBadges = badges.filter { liveIds.contains($0.key) }
        if prunedBadges.count != badges.count {
            badges = prunedBadges
        }
        let prunedIcons = dynamicIcons.filter { liveIds.contains($0.key) }
        if prunedIcons.count != dynamicIcons.count {
            dynamicIcons = prunedIcons
        }
    }

    func refreshExtensions() {
        ChromiumLauncher.sharedInstance().bridge?.getAllExtensions(completion: { infos in
            if let typedInfos = infos as? [[String: Any]] {
                self.extensionChanged(typedInfos)
            }
        }, windowId: browserState?.windowId.int64Value ?? 0)
    }
    
    // MARK: - Action badge / dynamic icon (pushed from Chromium per window)

    func handleBadgeInfo(_ info: [AnyHashable: Any]) {
        guard let extensionId = info["extensionId"] as? String else { return }
        if let state = Self.badgeState(from: info) {
            badges[extensionId] = state
        } else {
            badges.removeValue(forKey: extensionId)
        }
    }

    /// Parses a badge-info dictionary into a `BadgeState`, or `nil` when the
    /// action is fully default (no badge text, visible, enabled) and the entry
    /// should be removed. A hidden page action or a disabled action commonly has
    /// empty badge text, so removal keys on text *and* visible *and* enabled —
    /// otherwise the renderer would lose the state it needs to hide / grayscale.
    /// Pure; exposed for unit testing.
    static func badgeState(from info: [AnyHashable: Any]) -> BadgeState? {
        let text = info["badgeText"] as? String ?? ""
        let visible = info["visible"] as? Bool ?? true
        let enabled = info["enabled"] as? Bool ?? true
        if text.isEmpty && visible && enabled {
            return nil
        }
        return BadgeState(
            text: text,
            backgroundColor: NSColor.fromRGBAString(info["backgroundColor"] as? String ?? ""),
            textColor: NSColor.fromRGBAString(info["textColor"] as? String ?? ""),
            visible: visible,
            enabled: enabled)
    }

    func handleIconInfo(_ info: [AnyHashable: Any]) {
        guard let extensionId = info["extensionId"] as? String else { return }
        guard let data = info["iconData"] as? Data, !data.isEmpty else {
            dynamicIcons.removeValue(forKey: extensionId)
            return
        }
        guard let image = NSImage(data: data) else {
            dynamicIcons.removeValue(forKey: extensionId)
            return
        }
        if let dip = info["dipSize"] as? Double, dip > 0 {
            image.size = NSSize(width: dip, height: dip)
        }
        dynamicIcons[extensionId] = image
    }

    func togglePin(_ model: Extension) {
        if !model.isPinned {
            ChromiumLauncher.sharedInstance().bridge?.pinExtension(withId: model.id, windowId: Int64(browserState?.windowId ?? 0))
        } else {
            ChromiumLauncher.sharedInstance().bridge?.unpinExtension(withId: model.id, windowId: Int64(browserState?.windowId ?? 0))
        }
    }
    
    #if DEBUG
    func loadTestData(itemCount: Int) {
        guard itemCount >= 0 else { return }
        
        let mockData: [[String: Any]]
        if itemCount == 0 {
            mockData = []
        } else {
            mockData = (1...itemCount).map { i -> [String: Any] in
                let shouldPin = i <= min(4, max(1, itemCount / 4))
                return [
                    "id": "test_\(i)",
                    "name": "Test Extension \(i)",
                    "version": "1.0.0",
                    "isPinned": shouldPin,
                    "pinnedIndex": shouldPin ? i : -1
                ]
            }
        }
        extensionChanged(mockData)
    }
    #endif
}

extension NSColor {
    /// Parses Chromium's `color_utils::SkColorToRgbaString` output —
    /// `rgba(R,G,B,A)` with R/G/B in 0..255 and A in 0..1. Returns `.clear`
    /// on any parse failure.
    static func fromRGBAString(_ s: String) -> NSColor {
        guard let open = s.firstIndex(of: "("),
              let close = s.firstIndex(of: ")") else { return .clear }
        let parts = s[s.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let r = Double(parts[0]), let g = Double(parts[1]),
              let b = Double(parts[2]), let a = Double(parts[3]) else { return .clear }
        return NSColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
    }
}

extension ExtensionManager {
    /// The icon to display for `extensionId`: the dynamic action icon (setIcon /
    /// declarative) if set, else the static manifest icon, else a puzzlepiece
    /// fallback. The badge is NOT composited here — it is drawn as an overlay
    /// (`extensionBadgeOverlay` in SwiftUI, `BadgeCornerOverlay` hosted on AppKit
    /// surfaces) anchored to the icon's bottom-right corner.
    func iconImage(extensionId: String, staticIcon: NSImage?) -> NSImage {
        dynamicIcons[extensionId]
            ?? staticIcon
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            ?? NSImage()
    }
}

