// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SidebarNewTabStickyResolverTests: XCTestCase {
    func testShowsFloatingCellAfterNewTabRowCrossesVisibleTop() {
        let rowRect = CGRect(x: 0, y: 80, width: 240, height: 36)
        let visibleRect = CGRect(x: 0, y: 90, width: 240, height: 400)

        XCTAssertTrue(SidebarNewTabStickyResolver.shouldShowFloatingNewTab(rowRect: rowRect, visibleRect: visibleRect))
    }

    func testDoesNotShowFloatingCellWhenNewTabRowIsAtVisibleTop() {
        let rowRect = CGRect(x: 0, y: 80, width: 240, height: 36)
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 400)

        XCTAssertFalse(SidebarNewTabStickyResolver.shouldShowFloatingNewTab(rowRect: rowRect, visibleRect: visibleRect))
    }

    func testDoesNotShowFloatingCellBeforeNewTabRowReachesVisibleTop() {
        let rowRect = CGRect(x: 0, y: 120, width: 240, height: 36)
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 400)

        XCTAssertFalse(SidebarNewTabStickyResolver.shouldShowFloatingNewTab(rowRect: rowRect, visibleRect: visibleRect))
    }
}
