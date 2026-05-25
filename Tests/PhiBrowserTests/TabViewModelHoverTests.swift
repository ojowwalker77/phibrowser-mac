// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class TabViewModelHoverTests: XCTestCase {
    func testConfigureResetsHoverSuppressionState() {
        let model = TabViewModel()
        model.setHovered(true)
        model.setHoverSuppressed(true)

        let tab = Tab(guid: 1, url: "https://example.com", isActive: false, index: 0, title: "Example")
        model.configure(with: tab)

        XCTAssertFalse(model.isHovered)
        XCTAssertFalse(model.isHoverSuppressed)
    }
}
