// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Tests for the renderer crash page's pure logic: the bridge payload contract
/// (CrashPageData parsing, the locally-derived primary action, and Equatable for
/// overlay dedup) and the cross-window-drag crash buffer in PhiChromiumCoordinator.
/// The UI/hosting behaviour (z-order, split overlays, window sizing) is manual E2E.
///
/// @MainActor for the buffer tests, which drive the coordinator's main-actor
/// show/hide selectors; the parsing tests are main-actor-agnostic and run there too.
@MainActor
final class CrashPageDataTests: XCTestCase {
    private let coordinator = PhiChromiumCoordinator.shared

    private func dict(showFeedback: Bool,
                      tips: [String] = [],
                      errorCodeText: String = "Error code: SIGSEGV") -> [AnyHashable: Any] {
        [
            "title": "Aw, Snap!",
            "message": "Something went wrong while displaying this webpage.",
            "buttonLabel": showFeedback ? "Send feedback" : "Reload",
            "helpLinkLabel": "Learn more",
            "errorCodeText": errorCodeText,
            "tips": tips,
            "helpLinkUrl": "https://phibrowser.com/help/",
            "showFeedbackButton": NSNumber(value: showFeedback),
            "isRepeatedlyCrashing": NSNumber(value: showFeedback),
            "errorCode": NSNumber(value: 11),
            "kind": NSNumber(value: 1),
            "terminationStatus": NSNumber(value: 2),
        ]
    }

    func testParsesAllFields() {
        let data = CrashPageData(dictionary: dict(showFeedback: false))
        XCTAssertEqual(data.title, "Aw, Snap!")
        XCTAssertEqual(data.message, "Something went wrong while displaying this webpage.")
        XCTAssertEqual(data.buttonLabel, "Reload")
        XCTAssertEqual(data.helpLinkLabel, "Learn more")
        XCTAssertEqual(data.errorCodeText, "Error code: SIGSEGV")
        XCTAssertEqual(data.helpLinkUrl, "https://phibrowser.com/help/")
        XCTAssertEqual(data.errorCode, 11)
        XCTAssertEqual(data.kind, 1)
        XCTAssertEqual(data.terminationStatus, 2)
        XCTAssertFalse(data.showFeedbackButton)
        XCTAssertFalse(data.isRepeatedlyCrashing)
    }

    func testPrimaryActionIsReloadWhenFeedbackButtonOff() {
        let data = CrashPageData(dictionary: dict(showFeedback: false))
        XCTAssertEqual(data.primaryAction, .reload)
    }

    func testPrimaryActionIsReloadWhenLegacyFeedbackButtonIsOn() {
        let data = CrashPageData(dictionary: dict(showFeedback: true))
        XCTAssertEqual(data.primaryAction, .reload)
        XCTAssertEqual(data.buttonLabel, "Reload")
        XCTAssertTrue(data.showFeedbackButton)
    }

    func testTipsParsedAsStringArray() {
        let data = CrashPageData(dictionary: dict(showFeedback: true, tips: ["one", "two"]))
        XCTAssertEqual(data.tips, ["one", "two"])
    }

    func testMissingKeysFallBackToDefaults() {
        let data = CrashPageData(dictionary: [:])
        XCTAssertEqual(data.title, "")
        XCTAssertEqual(data.message, "")
        XCTAssertEqual(data.tips, [])
        XCTAssertEqual(data.helpLinkUrl, "")
        XCTAssertEqual(data.errorCode, 0)
        XCTAssertFalse(data.showFeedbackButton)
        XCTAssertEqual(data.primaryAction, .reload)
    }

    func testEmptyErrorCodeTextIsEmpty() {
        let data = CrashPageData(dictionary: dict(showFeedback: false, errorCodeText: ""))
        XCTAssertTrue(data.errorCodeText.isEmpty)
    }

    func testEquatable() {
        let a = CrashPageData(dictionary: dict(showFeedback: false))
        let b = CrashPageData(dictionary: dict(showFeedback: false))
        let differentData = CrashPageData(dictionary: dict(showFeedback: true, tips: ["x"]))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, differentData)
    }

    // MARK: - Cross-window crash buffer (PhiChromiumCoordinator)
    // These ids resolve to no live window, so showCrashPage always takes the
    // buffer path and hideCrashPage always takes the unresolved path. Each test
    // drains its own id, leaving the shared coordinator buffer clean for others.

    func testShowBuffersCrashForUnresolvedTab() {
        let tabId: Int64 = 990001
        coordinator.showCrashPage(tabId, windowId: 880001, data: ["title": "Aw, Snap!"])
        XCTAssertNotNil(coordinator.drainPendingCrash(tabId: Int(tabId)),
                        "A crash for a not-yet-created tab must be buffered")
        XCTAssertNil(coordinator.drainPendingCrash(tabId: Int(tabId)),
                     "Draining must consume the buffered crash exactly once")
    }

    func testHideClearsBufferedCrashForUnresolvedTab() {
        let tabId: Int64 = 990002
        coordinator.showCrashPage(tabId, windowId: 880002, data: ["title": "Aw, Snap!"])
        coordinator.hideCrashPage(tabId, windowId: 880002)
        XCTAssertNil(coordinator.drainPendingCrash(tabId: Int(tabId)),
                     "hideCrashPage must drop a buffered crash for an unresolved tab")
    }
}
