// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// UI-side bridge from the data-layer `GroupColor` to a concrete `NSColor`
/// resolved against the asset catalog (light / dark variants live in
/// `Resources/Assets.xcassets/TabGroupColor/`). Kept out of `GroupColor.swift`
/// so the data folder doesn't depend on AppKit.
extension GroupColor {
    var nsColor: NSColor {
        switch self {
        case .grey:   return NSColor(resource: .tabGroupGrey)
        case .blue:   return NSColor(resource: .tabGroupBlue)
        case .red:    return NSColor(resource: .tabGroupRed)
        case .yellow: return NSColor(resource: .tabGroupYellow)
        case .green:  return NSColor(resource: .tabGroupGreen)
        case .pink:   return NSColor(resource: .tabGroupPink)
        case .purple: return NSColor(resource: .tabGroupPurple)
        case .cyan:   return NSColor(resource: .tabGroupCyan)
        case .orange: return NSColor(resource: .tabGroupOrange)
        }
    }

    /// Background tint for `TabGroupChipView`. ~18% of the saturated group
    /// color over whatever the strip background happens to be — the mix
    /// picks up the ambient surface so light and dark modes both get an
    /// "appropriately deep" chip behind the label.
    var chipTintColor: NSColor {
        nsColor.withAlphaComponent(0.18)
    }

    /// Hover variant of `chipTintColor` — slightly more saturated. Used
    /// when the cursor is over the chip to invite the click-to-collapse
    /// affordance.
    var chipHoverTintColor: NSColor {
        nsColor.withAlphaComponent(0.28)
    }
}

extension NSImage {
    /// Small rounded square swatch filled with a tab-group color. Sized
    /// for the leading-edge image of an `NSMenuItem` (used by the "Add
    /// to Group" submenu and the group header's "Change Color" submenu).
    ///
    /// Uses `NSImage(size:flipped:drawingHandler:)` (lazy redraw) so
    /// the dynamic `NSColor(resource:)` picks up the menu's current
    /// drawing appearance every time the swatch is rendered. Eager
    /// `lockFocus` would bake whichever variant resolved at swatch
    /// creation, which can mismatch the menu's actual appearance.
    static func tabGroupColorSwatch(for groupColor: GroupColor,
                                    size: NSSize = NSSize(width: 12, height: 12),
                                    cornerRadius: CGFloat = 3) -> NSImage {
        return NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(origin: .zero, size: size)
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: cornerRadius,
                                    yRadius: cornerRadius)
            groupColor.nsColor.setFill()
            path.fill()
            return true
        }
    }
}
