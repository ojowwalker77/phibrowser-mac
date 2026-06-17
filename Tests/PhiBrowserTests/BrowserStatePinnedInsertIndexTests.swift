// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Commit-side guard for pinned reorders: an insert index that would land
/// between a pinned split pair's two records snaps past the pair, keeping
/// the persisted record order aligned with the merged-cell rendering.
@MainActor
final class BrowserStatePinnedInsertIndexTests: XCTestCase {
    private func makePinnedPair() -> (first: Tab, second: Tab) {
        let first = Tab(url: "https://a.example", isActive: false, index: 0, customGuid: "db-first")
        let second = Tab(url: "https://b.example", isActive: false, index: 1, customGuid: "db-second")
        first.splitPartnerGuid = "db-second"
        second.splitPartnerGuid = "db-first"
        return (first, second)
    }

    private func makePlainPinned(_ dbGuid: String, index: Int) -> Tab {
        Tab(url: "https://plain.example", isActive: false, index: index, customGuid: dbGuid)
    }

    func test_indexBetweenPinnedSplitPairSnapsPastThePair() {
        let (first, second) = makePinnedPair()
        let plain = makePlainPinned("db-plain", index: 2)
        let tabs = [first, second, plain]

        XCTAssertEqual(BrowserState.pinnedInsertIndexOutsideSplitPair(1, pinnedTabs: tabs), 2,
            "An index between the pair's records must snap past the second pane.")
    }

    func test_indexOutsidePairStaysUnchanged() {
        let (first, second) = makePinnedPair()
        let plain = makePlainPinned("db-plain", index: 0)
        let tabs = [plain, first, second]

        XCTAssertEqual(BrowserState.pinnedInsertIndexOutsideSplitPair(0, pinnedTabs: tabs), 0)
        XCTAssertEqual(BrowserState.pinnedInsertIndexOutsideSplitPair(1, pinnedTabs: tabs), 1,
            "Inserting before the pair must stay put — only the pair's interior snaps.")
        XCTAssertEqual(BrowserState.pinnedInsertIndexOutsideSplitPair(2, pinnedTabs: tabs), 3,
            "An index between the pair's records must snap past the second pane.")
        XCTAssertEqual(BrowserState.pinnedInsertIndexOutsideSplitPair(3, pinnedTabs: tabs), 3,
            "Appending at the end must stay put.")
    }
}
