// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TabGroupChipWidthTests: XCTestCase {

    func test_named_expanded_includesCountBadge() {
        let width = TabGroupChipView.chipWidth(
            forTitle: "Work",
            hasUserSetTitle: true,
            memberCount: 5,
            isCollapsed: false
        )
        // leadingPad(6) + dot(16) + dotGap(6) + label("Work"@13pt~38) + safety(4)
        //   + countToLabelGap(6) + countBadge(~22) + rightPad(6)
        // ≈ 104. Allow ±20pt range for font measurement variance.
        XCTAssertGreaterThan(width, 84)
        XCTAssertLessThan(width, 125)
    }

    func test_named_collapsed_includesMosaicInsteadOfCount() {
        let expanded = TabGroupChipView.chipWidth(
            forTitle: "Work",
            hasUserSetTitle: true,
            memberCount: 5,
            isCollapsed: false
        )
        let collapsed = TabGroupChipView.chipWidth(
            forTitle: "Work",
            hasUserSetTitle: true,
            memberCount: 5,
            isCollapsed: true
        )
        // Both have a "thing" between label and chevron. The mosaic
        // is fixed 18pt; the count badge for a single-digit count is
        // ~17pt. They should be within ±8pt of each other.
        XCTAssertEqual(collapsed, expanded, accuracy: 8)
    }

    func test_unnamed_expanded_skipsBadge() {
        let withBadge = TabGroupChipView.chipWidth(
            forTitle: "Blue · 5 tabs",
            hasUserSetTitle: true,
            memberCount: 5,
            isCollapsed: false
        )
        let withoutBadge = TabGroupChipView.chipWidth(
            forTitle: "Blue · 5 tabs",
            hasUserSetTitle: false,
            memberCount: 5,
            isCollapsed: false
        )
        XCTAssertGreaterThan(withBadge, withoutBadge,
            "User-named chip should be wider — it includes the count badge.")
    }

    func test_unnamed_collapsed_widensVersusExpanded() {
        // Unnamed group: expanded has no badge, collapsed has mosaic
        // → collapse widens the chip by mosaic + countToLabelGap.
        let expanded = TabGroupChipView.chipWidth(
            forTitle: "Blue · 5 tabs",
            hasUserSetTitle: false,
            memberCount: 5,
            isCollapsed: false
        )
        let collapsed = TabGroupChipView.chipWidth(
            forTitle: "Blue · 5 tabs",
            hasUserSetTitle: false,
            memberCount: 5,
            isCollapsed: true
        )
        let delta = collapsed - expanded
        // Mosaic 28 + gap 6 = 34. Allow ±3.
        XCTAssertEqual(delta, 34, accuracy: 3,
            "Collapsing an unnamed group should widen the chip by mosaic + gap.")
    }

    func test_collapsed_widthDoesNotDependOnMemberCount() {
        // Mosaic is fixed-size regardless of whether overflow shows
        // (overflow lives inside slot 3, not as separate text width
        // budget).
        let smallGroup = TabGroupChipView.chipWidth(
            forTitle: "Work",
            hasUserSetTitle: true,
            memberCount: 2,
            isCollapsed: true
        )
        let bigGroup = TabGroupChipView.chipWidth(
            forTitle: "Work",
            hasUserSetTitle: true,
            memberCount: 100,
            isCollapsed: true
        )
        XCTAssertEqual(smallGroup, bigGroup, accuracy: 0.5,
            "Collapsed chip width should be invariant to memberCount.")
    }
}
