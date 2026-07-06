// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest

final class OverlayToastUITests: XCTestCase {
    private var app: XCUIApplication!

    private enum LayoutMode: String, CaseIterable {
        case comfortable
        case performance
        case balanced
    }

    private struct ToastCaseExpectation {
        let name: String
        let centerTitle: String?
        let centerMessage: String?
        let trailingTitle: String?
        let trailingMessage: String?

        var expectedTexts: [String] {
            [
                centerTitle,
                centerMessage,
                trailingTitle,
                trailingMessage
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        }
    }

    private static let toastCaseExpectations: [ToastCaseExpectation] = [
        ToastCaseExpectation(
            name: "Short Title And Message",
            centerTitle: "Center short title",
            centerMessage: "Center short message",
            trailingTitle: "Right short title",
            trailingMessage: "Right short message"
        ),
        ToastCaseExpectation(
            name: "Long Title And Message",
            centerTitle: "Center long title that wraps across the toast while staying readable inside the liquid glass surface",
            centerMessage: "Center long message with enough detail to exercise multi-line wrapping, vertical padding, and the fallback blur background without clipping text.",
            trailingTitle: "Right long title that checks trailing toast wrapping behavior near the window edge",
            trailingMessage: "Right long message that should remain legible while sharing the top edge with browser controls and window chrome."
        ),
        ToastCaseExpectation(
            name: "Title Only",
            centerTitle: "Center title only",
            centerMessage: nil,
            trailingTitle: "Right title only",
            trailingMessage: nil
        ),
        ToastCaseExpectation(
            name: "Message Only",
            centerTitle: nil,
            centerMessage: "Center message only",
            trailingTitle: nil,
            trailingMessage: "Right message only"
        )
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func test_launchArgumentDisplaysOverlayToastContentMatrix() throws {
        for layoutMode in LayoutMode.allCases {
            XCTContext.runActivity(named: "Layout \(layoutMode.rawValue)") { _ in
                launchToastMatrix(layoutMode: layoutMode)

                for toastCase in Self.toastCaseExpectations {
                    XCTContext.runActivity(named: toastCase.name) { _ in
                        waitForToastCase(toastCase)
                        attachScreenshot(named: "Overlay Toast - \(layoutMode.rawValue) - \(toastCase.name)")
                    }
                }

                app.terminate()
                app = nil
            }
        }
    }

    @MainActor
    private func launchToastMatrix(layoutMode: LayoutMode) {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest", "1",
            "-layoutMode", layoutMode.rawValue,
            "-spacesFeatureEnabled", "NO",
            "-overlayToastUITest", "1",
            "-overlayToastUITestAllCases", "1",
            "-overlayToastUITestDuration", "6",
            "--user-data-dir=\(NSTemporaryDirectory())PhiUITest-\(ProcessInfo.processInfo.globallyUniqueString)",
        ]
        app.launch()
        self.app = app

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 120),
                      "Main window did not appear")
        app.activate()
    }

    @MainActor
    private func waitForToastCase(
        _ toastCase: ToastCaseExpectation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for text in toastCase.expectedTexts {
            waitForStaticText(text, caseName: toastCase.name, file: file, line: line)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    @MainActor
    private func waitForStaticText(
        _ text: String,
        caseName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(
            format: "label == %@ OR value == %@",
            text,
            text
        )
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: 12),
            "Expected toast text did not appear for \(caseName): \(text)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        app.activate()
        Thread.sleep(forTimeInterval: 0.2)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
