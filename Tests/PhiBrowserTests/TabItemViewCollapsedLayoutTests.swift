// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class TabItemViewCollapsedLayoutTests: XCTestCase {
    func test_zeroSizedTabItemDoesNotExposeContentSubviews() {
        let view = TabItemView()
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Example",
            url: "https://example.com",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            sourceTab: nil
        ))

        view.frame = .zero
        view.layout()

        let visibleNonEmptySubviews = view.subviews.filter {
            !$0.isHidden && !$0.frame.isEmpty
        }

        XCTAssertTrue(
            visibleNonEmptySubviews.isEmpty,
            "Zero-sized tab items must not expose favicon/title subviews."
        )
    }
}
