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

    func testVisibleRectExcludesTopOverlayHeight() {
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 400)

        let result = SidebarNewTabStickyResolver.visibleRectExcludingTopOverlay(
            visibleRect: visibleRect,
            overlayHeight: 36
        )

        XCTAssertEqual(result, CGRect(x: 0, y: 116, width: 240, height: 364))
    }

    func testVisibleRectExcludingTopOverlayClampsToVisibleHeight() {
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 40)

        let result = SidebarNewTabStickyResolver.visibleRectExcludingTopOverlay(
            visibleRect: visibleRect,
            overlayHeight: 80
        )

        XCTAssertEqual(result, CGRect(x: 0, y: 120, width: 240, height: 0))
    }

    func testVisibleRectExcludingTopOverlayIgnoresNegativeHeight() {
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 400)

        let result = SidebarNewTabStickyResolver.visibleRectExcludingTopOverlay(
            visibleRect: visibleRect,
            overlayHeight: -12
        )

        XCTAssertEqual(result, visibleRect)
    }

    func testDragAutoscrollUsesTopOverlayAsObstructedArea() {
        let visibleRect = CGRect(x: 0, y: 100, width: 240, height: 400)

        let delta = SidebarDragAutoscrollResolver.scrollDelta(
            dragY: 150,
            visibleRect: visibleRect,
            isFlipped: true,
            topObstructionHeight: 36,
            hotZoneHeight: 92,
            minStep: 5,
            maxStep: 22
        )

        XCTAssertLessThan(delta, 0)
    }

    func testDragAutoscrollIgnoresPointerOutsideExpandedTopZone() {
        let visibleRect = CGRect(x: 0, y: 100, width: 240, height: 400)

        let delta = SidebarDragAutoscrollResolver.scrollDelta(
            dragY: 240,
            visibleRect: visibleRect,
            isFlipped: true,
            topObstructionHeight: 36,
            hotZoneHeight: 92,
            minStep: 5,
            maxStep: 22
        )

        XCTAssertEqual(delta, 0)
    }

    func testDragAutoscrollScrollsDownNearBottomEdge() {
        let visibleRect = CGRect(x: 0, y: 100, width: 240, height: 400)

        let delta = SidebarDragAutoscrollResolver.scrollDelta(
            dragY: 480,
            visibleRect: visibleRect,
            isFlipped: true,
            topObstructionHeight: 36,
            hotZoneHeight: 92,
            minStep: 5,
            maxStep: 22
        )

        XCTAssertGreaterThan(delta, 0)
    }
}
