// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SidebarBookmarkFolderDropResolverTests: XCTestCase {
    func testCollapsedFolderLowerHalfResolvesAfterFolder() {
        let target = SidebarBookmarkFolderDropResolver.resolve(
            isExpanded: false,
            isUpperHalf: false,
            isDropOnItem: true
        )

        XCTAssertEqual(target, .insertAfterFolder)
    }

    func testCollapsedFolderGapAboveResolvesBeforeFolder() {
        let target = SidebarBookmarkFolderDropResolver.resolve(
            isExpanded: false,
            isUpperHalf: true,
            isDropOnItem: false
        )

        XCTAssertEqual(target, .insertBeforeFolder)
    }

    func testCollapsedFolderUpperHalfOnTargetResolvesToDropOnFolder() {
        let target = SidebarBookmarkFolderDropResolver.resolve(
            isExpanded: false,
            isUpperHalf: true,
            isDropOnItem: true
        )

        XCTAssertEqual(target, .dropOnFolder)
        XCTAssertTrue(
            SidebarBookmarkFolderDropResolver.shouldHighlightFolder(
                isExpanded: false,
                isDropOnItem: true
            )
        )
    }

    func testCollapsedFolderGapDoesNotHighlightFolder() {
        XCTAssertFalse(
            SidebarBookmarkFolderDropResolver.shouldHighlightFolder(
                isExpanded: false,
                isDropOnItem: false
            )
        )
    }

    func testExpandedFolderGapKeepsChildInsertionTarget() {
        let target = SidebarBookmarkFolderDropResolver.resolve(
            isExpanded: true,
            isUpperHalf: false,
            isDropOnItem: false
        )

        XCTAssertEqual(target, .keepOriginal)
        XCTAssertFalse(
            SidebarBookmarkFolderDropResolver.shouldHighlightFolder(
                isExpanded: true,
                isDropOnItem: false
            )
        )
    }

    func testExpandedFolderOnTargetPreservesFirstChildInsertionBehavior() {
        let target = SidebarBookmarkFolderDropResolver.resolve(
            isExpanded: true,
            isUpperHalf: true,
            isDropOnItem: true
        )

        XCTAssertEqual(target, .insertAsFirstChild)
        XCTAssertFalse(
            SidebarBookmarkFolderDropResolver.shouldHighlightFolder(
                isExpanded: true,
                isDropOnItem: true
            )
        )
    }
}
