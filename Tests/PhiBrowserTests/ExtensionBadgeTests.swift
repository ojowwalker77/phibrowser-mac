// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class ExtensionBadgeTests: XCTestCase {

    // MARK: - NSColor.fromRGBAString

    func test_fromRGBAString_parsesComponents() {
        let color = NSColor.fromRGBAString("rgba(192,0,0,1)")
        let srgb = color.usingColorSpace(.sRGB)
        XCTAssertNotNil(srgb)
        XCTAssertEqual(srgb!.redComponent, 192.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb!.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(srgb!.blueComponent, 0, accuracy: 0.001)
        XCTAssertEqual(srgb!.alphaComponent, 1, accuracy: 0.001)
    }

    func test_fromRGBAString_parsesFractionalAlpha() {
        let color = NSColor.fromRGBAString("rgba(0,0,0,0.5)").usingColorSpace(.sRGB)
        XCTAssertEqual(color!.alphaComponent, 0.5, accuracy: 0.001)
    }

    func test_fromRGBAString_invalidReturnsClear() {
        XCTAssertEqual(NSColor.fromRGBAString("not a color"), .clear)
        XCTAssertEqual(NSColor.fromRGBAString("rgba(1,2,3)"), .clear)  // wrong count
        XCTAssertEqual(NSColor.fromRGBAString("rgba(a,b,c,d)"), .clear)  // non-numeric
    }

    // MARK: - ExtensionManager.badgeState(from:)

    func test_badgeState_fullyDefault_isRemoved() {
        // Empty text, visible, enabled => no entry (nil).
        XCTAssertNil(ExtensionManager.badgeState(from: ["badgeText": ""]))
        XCTAssertNil(ExtensionManager.badgeState(from: [
            "badgeText": "", "visible": true, "enabled": true,
        ]))
    }

    func test_badgeState_nonEmptyText_isKept() {
        let state = ExtensionManager.badgeState(from: [
            "badgeText": "12",
            "visible": true,
            "enabled": true,
            "backgroundColor": "rgba(192,0,0,1)",
            "textColor": "rgba(255,255,255,1)",
        ])
        XCTAssertEqual(state?.text, "12")
        XCTAssertEqual(state?.visible, true)
        XCTAssertEqual(state?.enabled, true)
    }

    func test_badgeState_hiddenWithEmptyText_isKept() {
        // Regression: a hidden page action with no badge text must retain its
        // visible=false so the renderer can hide it (would otherwise be dropped).
        let state = ExtensionManager.badgeState(from: [
            "badgeText": "", "visible": false, "enabled": true,
        ])
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.visible, false)
        XCTAssertEqual(state?.text, "")
    }

    func test_badgeState_disabledWithEmptyText_isKept() {
        let state = ExtensionManager.badgeState(from: [
            "badgeText": "", "visible": true, "enabled": false,
        ])
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.enabled, false)
    }

    func test_badgeState_defaultsVisibleEnabledWhenMissing() {
        let state = ExtensionManager.badgeState(from: ["badgeText": "5"])
        XCTAssertEqual(state?.visible, true)
        XCTAssertEqual(state?.enabled, true)
    }
}
