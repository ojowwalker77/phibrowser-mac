// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

public enum DefaultColors {
    public static let themeColor = ColorPair(
        light: NSColor(hex: 0x71717A),
        dark: NSColor(hex: 0x71717A)
    )
    
    public static let extensionActonColor = ColorPair(
        light: NSColor(hex: 0x2DC882),
        dark: NSColor(hex: 0x168A55)
    )
    
    public static let themeColorOnHover = ColorPair(
        light: NSColor(hex: 0x52525B),
        dark: NSColor(hex: 0xA1A1AA)
    )
    
    public static let textPrimary = ColorPair(
        light: NSColor(hex: 0x292724),
        dark: NSColor(hex: 0xE6E4E1)
    )
    
    public static let textPrimaryStrong = ColorPair(
        light: NSColor(hex: 0x171615),
        dark: NSColor(hex: 0xF5F3F0)
    )
    
    public static let textSecondary = ColorPair(
        light: NSColor(hex: 0x6B6965),
        dark: NSColor(hex: 0x9C9A96)
    )
    
    public static let textTertiary = ColorPair(
        light: NSColor(hex: 0x9C9A96),
        dark: NSColor(hex: 0x6B6965)
    )
    
    public static let windowOverlayBackground = ColorPair(
        light: NSColor(hex: 0xF2F0EC),
        dark: NSColor(hex: 0x171717)
    )
    
    public static let windowBackground = ColorPair(
        light: NSColor(hex: 0xE9E6E1),
        dark: NSColor(hex: 0x0A0A0A)
    )
    
    public static let settingItemBackground = ColorPair(
        light: NSColor.black.withAlphaComponent(0.04),
        dark: NSColor.white.withAlphaComponent(0.04)
    )
    
    public static let sidebarTabSelectedBackground = ColorPair(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.08)
    )
    
    public static let sidebarTabHoveredBackground = ColorPair(
        light: NSColor.black.withAlphaComponent(0.05),
        dark: NSColor.white.withAlphaComponent(0.05)
    )
    
    public static let border = ColorPair(
        light: NSColor.black.withAlphaComponent(0.10),
        dark: NSColor.white.withAlphaComponent(0.07)
    )
    
    public static let separator = ColorPair(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.07)
    )
    
    public static func colorPair(for role: ColorRole) -> ColorPair {
        switch role {
        case .themeColor:                   return themeColor
        case .themeColorOnHover:            return themeColorOnHover
        case .textPrimary:                  return textPrimary
        case .textPrimaryStrong:            return textPrimaryStrong
        case .textSecondary:                return textSecondary
        case .textTertiary:                 return textTertiary
        case .windowOverlayBackground:      return windowOverlayBackground
        case .windowBackground:             return windowBackground
        case .settingItemBackground:        return settingItemBackground
        case .sidebarTabSelectedBackground: return sidebarTabSelectedBackground
        case .sidebarTabHoveredBackground:  return sidebarTabHoveredBackground
        case .border:                       return border
        case .separator:                    return separator
        case .extensionActonColor:          return extensionActonColor
        }
    }
    
    public static func color(for role: ColorRole, appearance: Appearance) -> NSColor {
        colorPair(for: role).color(for: appearance)
    }
}
