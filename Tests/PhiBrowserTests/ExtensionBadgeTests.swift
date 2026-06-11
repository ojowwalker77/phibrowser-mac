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
        // Empty text, visible, enabled, not grayed => no entry (nil).
        XCTAssertNil(ExtensionManager.badgeState(from: ["badgeText": ""]))
        XCTAssertNil(ExtensionManager.badgeState(from: [
            "badgeText": "", "visible": true, "enabled": true, "grayscale": false,
        ]))
    }

    func test_badgeState_grayscaleWithEmptyText_isKept() {
        // A grayed action (disabled + no page interaction) with no badge text
        // must retain grayscale=true so the icon faces can gray it.
        let state = ExtensionManager.badgeState(from: [
            "badgeText": "", "visible": true, "enabled": false, "grayscale": true,
        ])
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.grayscale, true)
        XCTAssertEqual(state?.enabled, false)
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
        XCTAssertEqual(state?.grayscale, false)
    }

    // MARK: - ExtensionManager.actionRenderStates(_:)

    func test_actionRenderStates_ignoresDefaultRenderAndBadgeText() {
        // Badge-text ticks and click-only state (enabled) render default —
        // they must not gate a rebuild.
        let badges: [String: ExtensionManager.BadgeState] = [
            "a": .init(text: "12", backgroundColor: .red, textColor: .white,
                       visible: true, enabled: true, grayscale: false),
            "b": .init(text: "", backgroundColor: .clear, textColor: .clear,
                       visible: true, enabled: false, grayscale: false),
        ]
        XCTAssertTrue(ExtensionManager.actionRenderStates(badges).isEmpty)
    }

    func test_actionRenderStates_distinguishesHiddenFromGrayed() {
        func gate(visible: Bool, grayscale: Bool) -> Set<ExtensionManager.ActionRenderState> {
            ExtensionManager.actionRenderStates([
                "a": .init(text: "", backgroundColor: .clear, textColor: .clear,
                           visible: visible, enabled: false, grayscale: grayscale),
            ])
        }
        let hidden = gate(visible: false, grayscale: false)
        let grayed = gate(visible: true, grayscale: true)
        XCTAssertEqual(hidden.count, 1)
        XCTAssertEqual(grayed.count, 1)
        // A hidden↔grayed transition must change the gate value so the icon
        // faces rebuild (the grayed icon is baked at rebuild time).
        XCTAssertNotEqual(hidden, grayed)
    }

    // MARK: - NSImage.disabledActionVariant

    func test_disabledActionVariant_desaturatesAndLightens() {
        let red = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let variant = red.disabledActionVariant
        XCTAssertEqual(variant.size, red.size)
        guard let cg = variant.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("variant not drawable")
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let pixel = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.sRGB) else {
            return XCTFail("center pixel unreadable")
        }
        // Desaturated: channels converge. Lightened ~20% toward white
        // (Chrome's HSL {-1, 0, 0.6}): red's luma ≈ 0.21 → ≈ 0.37. Alpha is
        // untouched (Chrome does not dim disabled icons).
        XCTAssertEqual(pixel.redComponent, pixel.greenComponent, accuracy: 0.06)
        XCTAssertEqual(pixel.greenComponent, pixel.blueComponent, accuracy: 0.06)
        XCTAssertGreaterThan(pixel.redComponent, 0.2)
        XCTAssertLessThan(pixel.redComponent, 0.55)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.9)
    }
}
