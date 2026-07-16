// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

// MARK: - Predefined Themed Colors

public extension ThemedColor {

    static let themeColor = ThemedColor(role: .themeColor)
    
    static let themeColorOnHover = ThemedColor(role: .themeColorOnHover)

    static let extensionActonColor = ThemedColor(role: .extensionActonColor)

    // MARK: - Text Colors
    
    /// Primary text color.
    static let textPrimary = ThemedColor(role: .textPrimary)
    
    static let textPrimaryStrong = ThemedColor(role: .textPrimaryStrong)
    
    /// Secondary text color.
    static let textSecondary = ThemedColor(role: .textSecondary)
    
    /// Tertiary text color.
    static let textTertiary = ThemedColor(role: .textTertiary)
    
    
    // MARK: - Window Colors
    
    /// Window overlay background color.
    static let windowOverlayBackground = ThemedColor(role: .windowOverlayBackground)
    
    /// Default window background color.
    static let windowBackground = ThemedColor(role: .windowBackground)

    /// Opaque content overlay background shared by the address bar, bookmark bar, active tab, and split views.
    static let contentOverlayBackground = ThemedColor { theme, appearance in
        if appearance.isLight {
            return .white
        } else {
            return windowBackground.resolve(theme: theme, appearance: appearance)
        }
    }

    /// Background for tabs in the temporary multi-selection (excluding the active tab).
    /// Offset from `contentOverlayBackground` so a sub-selected tab reads as distinct
    /// from both the active tab and a hover.
    static let tabSubSelectionBackground = ThemedColor { theme, appearance in
        let base = contentOverlayBackground.resolve(theme: theme, appearance: appearance)
        return appearance.isLight
            ? base.adjustingBrightness(percent: -8)
            : base.adjustingBrightness(percent: 12)
    }
    
    // MARK: - Sidebar Colors
    
    /// Selected sidebar tab background color.
    static let sidebarTabSelectedBackground = ThemedColor(role: .sidebarTabSelectedBackground)
    
    /// Hovered sidebar tab background color.
    static let sidebarTabHoveredBackground = ThemedColor(role: .sidebarTabHoveredBackground)
    
    static let settingItemBackground = ThemedColor(role: .settingItemBackground)
    
    /// Alias for the generic hover background color.
    static let hover = ThemedColor(role: .sidebarTabHoveredBackground)
    
    // MARK: - Border & Separator
    
    /// Border color.
    static let border = ThemedColor(role: .border)
    
    /// Separator color.
    static let separator = ThemedColor(role: .separator)
    
    // MARK: - Convenience Initializers
    
    /// Creates a themed color from a light and dark pair.
    static func pair(_ light: NSColor, _ dark: NSColor) -> ThemedColor {
        ThemedColor(light: light, dark: dark)
    }
    
    /// Creates a themed color from light and dark hex values.
    static func hex(light: Int, dark: Int) -> ThemedColor {
        ThemedColor(lightHex: light, darkHex: dark)
    }
    
    /// Transparent themed color.
    static let clear = ThemedColor(.clear)
    
    /// White themed color.
    static let white = ThemedColor(.white)
    
    /// Black themed color.
    static let black = ThemedColor(.black)
}

// MARK: - ColorConvertible to ThemedColor

public extension ColorConvertible {
    /// Wraps the value as a fixed themed color.
    var themed: ThemedColor {
        ThemedColor(asColor())
    }
}

// MARK: - NSColor Themed Extension

public extension NSColor {
    /// Creates a fixed themed color.
    var themed: ThemedColor {
        ThemedColor(self)
    }
    
    /// Creates a light and dark themed color pair.
    func themedWith(dark: NSColor) -> ThemedColor {
        ThemedColor(light: self, dark: dark)
    }
}

extension Theme {
    /// Incognito theme — dedicated theme for private browsing windows.
    static let incognito: Theme = {
        let theme = Theme(id: "incognito", name: "Incognito")
        theme.setColor(ColorPair(NSColor(hex: 0xA78BFA)), for: .themeColor)
        return theme
    }()
}

private func makeDesignTheme(
    id: String,
    name: String,
    signatureColor: Int
) -> Theme {
    let theme = Theme(id: id, name: name)
    let signature = NSColor(hex: signatureColor)

    theme.setColor(ColorPair(signature), for: .themeColor)
    theme.setColor(ColorPair(signature), for: .extensionActonColor)
    theme.setColor(
        light: signature.adjustingBrightness(percent: -7),
        dark: signature.adjustingBrightness(percent: 5),
        for: .themeColorOnHover
    )

    return theme
}

// MARK: - Built-In Themes

public extension Theme {
    static let zinc = makeDesignTheme(
        id: "zinc",
        name: NSLocalizedString("Zinc", comment: "Zinc theme name"),
        signatureColor: 0x71717A
    )

    static let pink = makeDesignTheme(
        id: "pink",
        name: NSLocalizedString("Pink", comment: "Pink theme name"),
        signatureColor: 0xEF476F
    )

    static let yellow = makeDesignTheme(
        id: "yellow",
        name: NSLocalizedString("Yellow", comment: "Yellow theme name"),
        signatureColor: 0xFFD166
    )

    static let green = makeDesignTheme(
        id: "green",
        name: NSLocalizedString("Green", comment: "Green theme name"),
        signatureColor: 0x06D6A0
    )

    static let builtInThemes: [Theme] = [
        .zinc,
        .pink,
        .yellow,
        .green
    ]

    /// Removed palette identifiers all start from Zinc. This avoids silently
    /// turning an old choice into a newly introduced color after upgrading.
    static func migratedBuiltInThemeId(_ id: String) -> String {
        switch id {
        case "default", "pure", "mist", "mint", "aqua", "iris", "petal", "coral", "amber":
            return zinc.id
        default:
            return id
        }
    }
}
