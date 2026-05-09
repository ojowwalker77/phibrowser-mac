// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SidebarGroupDropResolverTests: XCTestCase {

    // MARK: - Helpers

    /// Frame builder for tests: a 36pt-tall row at the given midY in a
    /// non-flipped coordinate system.
    private func rowFrame(midY: CGFloat) -> CGRect {
        return CGRect(x: 0, y: midY - 18, width: 200, height: 36)
    }

    // MARK: - isUpperHalf helper

    func test_isUpperHalf_flippedCoordinates_aboveMid_returnsTrue() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 36)
        XCTAssertTrue(
            SidebarGroupDropResolver.isUpperHalf(
                cursorY: 5, frame: frame, isFlipped: true)
        )
    }

    func test_isUpperHalf_flippedCoordinates_belowMid_returnsFalse() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 36)
        XCTAssertFalse(
            SidebarGroupDropResolver.isUpperHalf(
                cursorY: 30, frame: frame, isFlipped: true)
        )
    }

    func test_isUpperHalf_nonFlippedCoordinates_aboveMid_returnsTrue() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 36)
        XCTAssertTrue(
            SidebarGroupDropResolver.isUpperHalf(
                cursorY: 30, frame: frame, isFlipped: false)
        )
    }

    func test_shouldResolve_returnsFalseForNonTabSectionTargets() {
        XCTAssertFalse(SidebarGroupDropResolver.shouldResolve(proposedItem: NSObject()))
    }

    func test_shouldResolve_returnsFalseForRootBookmarkSectionDrops() {
        XCTAssertFalse(SidebarGroupDropResolver.shouldResolve(
            proposedItem: nil,
            isRootBookmarkSectionDrop: true
        ))
    }

    func test_shouldResolve_returnsTrueForRootTabAndGroupTargets() {
        XCTAssertTrue(SidebarGroupDropResolver.shouldResolve(proposedItem: nil))
        XCTAssertTrue(SidebarGroupDropResolver.shouldResolve(
            proposedItem: stubTab(guid: 1001, token: nil)
        ))
        XCTAssertTrue(SidebarGroupDropResolver.shouldResolve(
            proposedItem: stubGroupWrapper(token: "A")
        ))
    }

    // MARK: - Helpers (continued)
    //
    // Stub strategy: the resolver depends on `TabGroupSidebarItem` only
    // for its `group.token` accessor. Building a real
    // `TabGroupSidebarItem` would require a `BrowserState`, which is
    // `@MainActor`, owns a `LocalStore`, and spins up Combine
    // subscriptions — far too heavy for a pure unit test. Instead the
    // resolver casts to a small `SidebarGroupHeaderItem` protocol
    // (declared next to the resolver). Tests provide a lightweight
    // class conforming to that protocol via `stubGroupWrapper(token:)`.
    // `Tab`, by contrast, is constructible directly without
    // `BrowserState`, so `stubTab(guid:token:)` just calls its public
    // initializer.

    private final class StubGroupHeaderItem: SidebarGroupHeaderItem {
        let wrappedGroupToken: String
        init(token: String) { self.wrappedGroupToken = token }
    }

    private func stubGroupWrapper(token: String) -> SidebarGroupHeaderItem {
        return StubGroupHeaderItem(token: token)
    }

    /// Per-test side table mapping a stubbed `Tab`'s identity to its
    /// simulated `normalTabs` index. The resolver's sameSlot
    /// post-process needs the dragged tab's current position; ctx
    /// builders read it back here so callers don't have to thread an
    /// extra parameter through every builder for tests that don't
    /// care about sameSlot.
    private var stubTabNormalTabsIdx: [ObjectIdentifier: Int] = [:]

    private func stubTab(
        guid: Int,
        token: String?,
        idxInNormalTabs: Int? = nil
    ) -> Tab {
        let tab = Tab(guid: guid, url: nil, isActive: false, index: 0)
        tab.groupToken = token
        if let idx = idxInNormalTabs {
            stubTabNormalTabsIdx[ObjectIdentifier(tab)] = idx
        }
        return tab
    }

    private func normalTabsIdx(for tab: Tab?) -> Int? {
        guard let tab = tab else { return nil }
        return stubTabNormalTabsIdx[ObjectIdentifier(tab)]
    }

    /// Build a context for tests where a group wrapper is the
    /// proposedItem. Layout assumed by the test matrix:
    ///   normalTabs idx 0: Tab N1 (no group)
    ///   normalTabs idx 1: Tab A1 (token "A")
    ///   normalTabs idx 2: Tab A2 (token "A")
    ///   normalTabs idx 3: Tab B1 (token "B")
    ///   normalTabs idx 4: Tab B2 (token "B")
    ///   normalTabs idx 5: Tab N2 (no group)
    private func ctxWithWrapper(
        wrapper: SidebarGroupHeaderItem,
        cursorAboveMid: Bool,
        draggingTab: Tab?,
        pasteboard: PasteboardKind = .normalTab,
        isCrossWindow: Bool = false
    ) -> SidebarGroupDropContext {
        let frame = rowFrame(midY: 100)
        // Cursor is INSIDE the wrapper row frame [82, 118] so the
        // resolver treats this as "drop on header" and applies the
        // cursor.y-vs-midY rule. In non-flipped coords, larger y =
        // upper half.
        let cursorY: CGFloat = cursorAboveMid ? 108 : 92
        return SidebarGroupDropContext(
            proposedItem: wrapper,
            // -1 = NSOutlineViewDropOnItemIndex; matches AppKit's
            // "drop on the wrapper row body" report.
            proposedChildIndex: -1,
            cursorYInOutline: cursorY,
            outlineIsFlipped: false,
            rowFrameForProposedItem: frame,
            pasteboardKind: pasteboard,
            isCrossWindow: isCrossWindow,
            crossWindowAccepted: !isCrossWindow,
            draggingTab: draggingTab,
            memberIdxInGroupForProposedTab: nil,
            groupRangeInNormalTabs: { token in
                switch token {
                case "A": return 1..<3
                case "B": return 3..<5
                default:  return nil
                }
            },
            resolveNormalTabsIdx: { outlineIdx in
                // Tests don't exercise root drops here.
                return outlineIdx
            },
            normalTabsIdxForProposedTab: nil,
            draggingTabNormalTabsIdx: normalTabsIdx(for: draggingTab)
        )
    }

    /// Variant for "AppKit reports `(wrapper, k)` with cursor in the
    /// wrapper's expanded children area" — covers the bug where
    /// expanded-group drops were misclassified as joinAtFront because
    /// cursor.y was always below the wrapper's row.midY.
    private func ctxWithWrapperChildIndex(
        wrapper: SidebarGroupHeaderItem,
        proposedChildIndex: Int,
        draggingTab: Tab?,
        pasteboard: PasteboardKind = .normalTab,
        isCrossWindow: Bool = false
    ) -> SidebarGroupDropContext {
        let frame = rowFrame(midY: 100)
        // Cursor below the wrapper row frame entirely (in the
        // expanded children area). minY=82, maxY=118; pick y=200.
        let cursorY: CGFloat = 200
        return SidebarGroupDropContext(
            proposedItem: wrapper,
            proposedChildIndex: proposedChildIndex,
            cursorYInOutline: cursorY,
            outlineIsFlipped: false,
            rowFrameForProposedItem: frame,
            pasteboardKind: pasteboard,
            isCrossWindow: isCrossWindow,
            crossWindowAccepted: !isCrossWindow,
            draggingTab: draggingTab,
            memberIdxInGroupForProposedTab: nil,
            groupRangeInNormalTabs: { token in
                switch token {
                case "A": return 1..<3
                case "B": return 3..<5
                default:  return nil
                }
            },
            resolveNormalTabsIdx: { outlineIdx in outlineIdx },
            normalTabsIdxForProposedTab: nil,
            draggingTabNormalTabsIdx: normalTabsIdx(for: draggingTab)
        )
    }

    // MARK: - case 1: group header (foreign tab dragging in)

    func test_resolver_caseHeader_normalTab_upperHalf_returnsRootInsertBeforeGroup() {
        let wrapper = stubGroupWrapper(token: "A")
        let ctx = ctxWithWrapper(
            wrapper: wrapper,
            cursorAboveMid: true,
            draggingTab: nil
        )
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rootInsert(normalTabsIdx: 1)
        )
    }

    func test_resolver_caseHeader_normalTab_lowerHalf_returnsJoinAtFront() {
        let wrapper = stubGroupWrapper(token: "A")
        let ctx = ctxWithWrapper(
            wrapper: wrapper,
            cursorAboveMid: false,
            draggingTab: nil
        )
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .joinAtFront(token: "A", normalTabsIdx: 1)
        )
    }

    func test_resolver_caseHeader_ownGroupMember_lowerHalf_reordersToFront() {
        // Dragging A1 (already in A); cursor on A header lower half.
        // Resolver outputs reorderInGroup, not joinAtFront.
        let wrapper = stubGroupWrapper(token: "A")
        let memberA1 = stubTab(guid: 2001, token: "A")
        let ctx = ctxWithWrapper(
            wrapper: wrapper,
            cursorAboveMid: false,
            draggingTab: memberA1
        )
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .reorderInGroup(token: "A", normalTabsIdx: 1)
        )
    }

    // MARK: - case 2: group member row

    private func ctxWithMember(
        memberTab: Tab,
        memberIdxInGroup: Int,
        cursorAboveMid: Bool,
        draggingTab: Tab?,
        pasteboard: PasteboardKind = .normalTab,
        isCrossWindow: Bool = false
    ) -> SidebarGroupDropContext {
        let frame = rowFrame(midY: 100)
        let cursorY: CGFloat = cursorAboveMid ? 130 : 70
        return SidebarGroupDropContext(
            proposedItem: memberTab,
            proposedChildIndex: -1,
            cursorYInOutline: cursorY,
            outlineIsFlipped: false,
            rowFrameForProposedItem: frame,
            pasteboardKind: pasteboard,
            isCrossWindow: isCrossWindow,
            crossWindowAccepted: !isCrossWindow,
            draggingTab: draggingTab,
            memberIdxInGroupForProposedTab: memberIdxInGroup,
            groupRangeInNormalTabs: { token in
                switch token {
                case "A": return 1..<3
                case "B": return 3..<5
                default:  return nil
                }
            },
            resolveNormalTabsIdx: { _ in 0 },
            normalTabsIdxForProposedTab: nil,
            draggingTabNormalTabsIdx: normalTabsIdx(for: draggingTab)
        )
    }

    func test_resolver_caseMember_upperHalfOfA1_returnsReorderAtA1() {
        let n1 = stubTab(guid: 1001, token: nil)              // dragging
        let a1 = stubTab(guid: 2001, token: "A")              // proposed row
        let ctx = ctxWithMember(
            memberTab: a1, memberIdxInGroup: 0,
            cursorAboveMid: true, draggingTab: n1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .reorderInGroup(token: "A", normalTabsIdx: 1)
        )
    }

    func test_resolver_caseMember_lowerHalfOfA1_returnsReorderAfterA1() {
        let n1 = stubTab(guid: 1001, token: nil)
        let a1 = stubTab(guid: 2001, token: "A")
        let ctx = ctxWithMember(
            memberTab: a1, memberIdxInGroup: 0,
            cursorAboveMid: false, draggingTab: n1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .reorderInGroup(token: "A", normalTabsIdx: 2)
        )
    }

    func test_resolver_caseMember_lowerHalfOfA2_returnsJoinAsLast() {
        let n1 = stubTab(guid: 1001, token: nil)
        let a2 = stubTab(guid: 2002, token: "A")
        let ctx = ctxWithMember(
            memberTab: a2, memberIdxInGroup: 1,
            cursorAboveMid: false, draggingTab: n1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .reorderInGroup(token: "A", normalTabsIdx: 3)
        )
    }

    func test_resolver_caseMember_crossGroup_A1draggedOntoB1_returnsJoinB() {
        let a1 = stubTab(guid: 2001, token: "A")              // dragging
        let b1 = stubTab(guid: 3001, token: "B")              // proposed row
        let ctx = ctxWithMember(
            memberTab: b1, memberIdxInGroup: 0,
            cursorAboveMid: false, draggingTab: a1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .reorderInGroup(token: "B", normalTabsIdx: 4)
        )
    }

    // MARK: - case 3 + 4: normal tab row / nil root

    private func ctxWithNormalTab(
        tab: Tab,
        normalTabsIdx: Int,
        cursorAboveMid: Bool,
        draggingTab: Tab?,
        pasteboard: PasteboardKind = .normalTab
    ) -> SidebarGroupDropContext {
        let frame = rowFrame(midY: 100)
        let cursorY: CGFloat = cursorAboveMid ? 130 : 70
        return SidebarGroupDropContext(
            proposedItem: tab,
            proposedChildIndex: -1,
            cursorYInOutline: cursorY,
            outlineIsFlipped: false,
            rowFrameForProposedItem: frame,
            pasteboardKind: pasteboard,
            isCrossWindow: false,
            crossWindowAccepted: true,
            draggingTab: draggingTab,
            memberIdxInGroupForProposedTab: nil,
            groupRangeInNormalTabs: { _ in nil },
            resolveNormalTabsIdx: { _ in 0 },
            normalTabsIdxForProposedTab: normalTabsIdx,
            draggingTabNormalTabsIdx: self.normalTabsIdx(for: draggingTab)
        )
    }

    func test_resolver_caseNormalTab_upperHalf_returnsRootInsertBefore() {
        let n2 = stubTab(guid: 1002, token: nil)
        let n1 = stubTab(guid: 1001, token: nil)
        let ctx = ctxWithNormalTab(
            tab: n2, normalTabsIdx: 5,
            cursorAboveMid: true, draggingTab: n1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rootInsert(normalTabsIdx: 5)
        )
    }

    func test_resolver_caseNormalTab_lowerHalf_returnsRootInsertAfter() {
        let n2 = stubTab(guid: 1002, token: nil)
        let n1 = stubTab(guid: 1001, token: nil)
        let ctx = ctxWithNormalTab(
            tab: n2, normalTabsIdx: 5,
            cursorAboveMid: false, draggingTab: n1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rootInsert(normalTabsIdx: 6)
        )
    }

    // MARK: - case 5: rejections

    func test_resolver_crossWindow_groupHeaderLowerHalf_rejectsCrossWindowGroupJoin() {
        let wrapper = stubGroupWrapper(token: "A")
        let ctx = ctxWithWrapper(
            wrapper: wrapper,
            cursorAboveMid: false,
            draggingTab: nil,
            isCrossWindow: true)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rejected(reason: .crossWindowGroupJoinUnsupported)
        )
    }

    func test_resolver_pinnedTab_groupHeaderLowerHalf_rejectsPinnedInGroup() {
        let wrapper = stubGroupWrapper(token: "A")
        let ctx = ctxWithWrapper(
            wrapper: wrapper,
            cursorAboveMid: false,
            draggingTab: nil,
            pasteboard: .pinnedTab)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rejected(reason: .pinnedNotAllowedInGroup)
        )
    }

    func test_resolver_bookmark_memberRow_rejectsBookmarkInGroup() {
        let n1 = stubTab(guid: 1001, token: nil)
        let a1 = stubTab(guid: 2001, token: "A")
        let ctx = ctxWithMember(
            memberTab: a1, memberIdxInGroup: 0,
            cursorAboveMid: true, draggingTab: n1,
            pasteboard: .phiBookmark)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rejected(reason: .bookmarkNotAllowedInGroup)
        )
    }

    func test_resolver_caseNilProposedItem_returnsRootInsertWithTranslatedIdx() {
        let n1 = stubTab(guid: 1001, token: nil)
        let ctx = SidebarGroupDropContext(
            proposedItem: nil,
            proposedChildIndex: 7,                           // outline rootIdx
            cursorYInOutline: 0,
            outlineIsFlipped: false,
            rowFrameForProposedItem: nil,
            pasteboardKind: .normalTab,
            isCrossWindow: false,
            crossWindowAccepted: true,
            draggingTab: n1,
            memberIdxInGroupForProposedTab: nil,
            groupRangeInNormalTabs: { _ in nil },
            resolveNormalTabsIdx: { outlineIdx in
                XCTAssertEqual(outlineIdx, 7)
                return 6                                     // mocked translation
            },
            normalTabsIdxForProposedTab: nil,
            draggingTabNormalTabsIdx: nil
        )
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rootInsert(normalTabsIdx: 6)
        )
    }

    // MARK: - sameSlot

    func test_resolver_sameSlot_normalTabAlreadyInTargetRoot_rejects() {
        // N1 at idx 0; intent = .rootInsert(1). After moveNormalTabLocally(0, 1):
        // postMoveIdx = max(0, 1-1) = 0 == oldIdx. Token unchanged (nil → nil). sameSlot.
        let n1 = stubTab(guid: 1001, token: nil, idxInNormalTabs: 0)
        let wrapper = stubGroupWrapper(token: "A")
        let ctx = ctxWithWrapper(
            wrapper: wrapper,
            cursorAboveMid: true,
            draggingTab: n1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rejected(reason: .sameSlot)
        )
    }

    func test_resolver_sameSlot_groupMemberDroppedOnSelfUpperHalf_rejects() {
        // A1 in A at idx 1; cursor on A1 upper half → reorderInGroup("A", 1).
        // Token unchanged. PostMoveIdx = 1 == oldIdx. sameSlot.
        let a1 = stubTab(guid: 2001, token: "A", idxInNormalTabs: 1)
        let ctx = ctxWithMember(
            memberTab: a1, memberIdxInGroup: 0,
            cursorAboveMid: true, draggingTab: a1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rejected(reason: .sameSlot)
        )
    }

    func test_resolver_groupMember_droppedOnHeaderUpperHalf_changesToken_notSameSlot() {
        // A1 in A at idx 1; cursor on A header upper half → .rootInsert(1).
        // PostMoveIdx = 1 == oldIdx, BUT token changes "A" → nil → NOT sameSlot.
        let a1 = stubTab(guid: 2001, token: "A", idxInNormalTabs: 1)
        let wrapper = stubGroupWrapper(token: "A")
        let ctx = ctxWithWrapper(
            wrapper: wrapper,
            cursorAboveMid: true,
            draggingTab: a1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rootInsert(normalTabsIdx: 1)
        )
    }

    // MARK: - case 1 (expanded children area): wrapper proposedItem +
    // cursor outside row + childIndex >= 0
    //
    // Regression coverage for the bug where expanded-group drops were
    // routed through the cursor.y-vs-midY rule against the *wrapper*
    // row, which sits at the top of the group. With expanded members
    // visible, the cursor falls below wrapper.maxY for any drop in the
    // children gap — `isUpperHalf` returned false → resolver always
    // produced `.joinAtFront`, so every drop landed at the front of
    // the group regardless of where the user aimed. AppKit's
    // `proposedChildIndex` is the authoritative signal in that
    // regime; resolver consults it directly when cursor is outside
    // the wrapper's row frame.

    func test_resolver_caseHeaderChildIdx_normalTabBetweenA1A2_returnsReorder() {
        // AppKit reports (wrapper, 1): cursor between A1 (lowerBound)
        // and A2 (lowerBound+1) in the expanded children area.
        // Foreign normal tab → reorderInGroup at lowerBound + 1 = 2.
        let wrapper = stubGroupWrapper(token: "A")
        let n1 = stubTab(guid: 1001, token: nil, idxInNormalTabs: 0)
        let ctx = ctxWithWrapperChildIndex(
            wrapper: wrapper,
            proposedChildIndex: 1,
            draggingTab: n1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .reorderInGroup(token: "A", normalTabsIdx: 2)
        )
    }

    func test_resolver_caseHeaderChildIdx_normalTabAtChildZero_returnsJoinAtFront() {
        // AppKit reports (wrapper, 0): cursor below wrapper row but
        // before any visible child (gap between header and A1).
        // For a foreign tab this is the group's first slot, so the
        // resolver prefers the more-specific .joinAtFront variant.
        let wrapper = stubGroupWrapper(token: "A")
        let n1 = stubTab(guid: 1001, token: nil, idxInNormalTabs: 0)
        let ctx = ctxWithWrapperChildIndex(
            wrapper: wrapper,
            proposedChildIndex: 0,
            draggingTab: n1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .joinAtFront(token: "A", normalTabsIdx: 1)
        )
    }

    func test_resolver_caseHeaderChildIdx_normalTabAtChildCount_returnsJoinAsLast() {
        // AppKit reports (wrapper, 2): cursor below the last expanded
        // member. Foreign tab → join as last member at lowerBound + 2 = 3.
        let wrapper = stubGroupWrapper(token: "A")
        let n1 = stubTab(guid: 1001, token: nil, idxInNormalTabs: 0)
        let ctx = ctxWithWrapperChildIndex(
            wrapper: wrapper,
            proposedChildIndex: 2,
            draggingTab: n1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .reorderInGroup(token: "A", normalTabsIdx: 3)
        )
    }

    func test_resolver_caseHeaderChildIdx_ownGroupMemberBetweenSelfAndA2_isSameSlot() {
        // A1 (idx 1) dragged; AppKit reports (A wrapper, 1) for
        // cursor in the gap between A1 and A2. Intent = reorder at
        // lowerBound + 1 = 2; postMoveIdx for from<to is 1 → equals
        // oldIdx → sameSlot.
        let wrapper = stubGroupWrapper(token: "A")
        let a1 = stubTab(guid: 2001, token: "A", idxInNormalTabs: 1)
        let ctx = ctxWithWrapperChildIndex(
            wrapper: wrapper,
            proposedChildIndex: 1,
            draggingTab: a1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rejected(reason: .sameSlot)
        )
    }

    func test_resolver_caseHeaderChildIdx_ownGroupMemberMovesToEnd_returnsReorder() {
        // A1 (idx 1) dragged to (A wrapper, 2) = position past last
        // child. Intent = reorder at lowerBound + 2 = 3; from < to
        // → postMoveIdx = max(0, 3-1) = 2 ≠ oldIdx → not sameSlot.
        let wrapper = stubGroupWrapper(token: "A")
        let a1 = stubTab(guid: 2001, token: "A", idxInNormalTabs: 1)
        let ctx = ctxWithWrapperChildIndex(
            wrapper: wrapper,
            proposedChildIndex: 2,
            draggingTab: a1)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .reorderInGroup(token: "A", normalTabsIdx: 3)
        )
    }

    func test_resolver_caseHeaderChildIdx_crossWindowRejected() {
        // Cross-window drop into expanded group children area is
        // unsupported (Phase 3 boundary). Same as the header-on
        // case but matches both code paths.
        let wrapper = stubGroupWrapper(token: "A")
        let n1 = stubTab(guid: 1001, token: nil, idxInNormalTabs: 0)
        let ctx = ctxWithWrapperChildIndex(
            wrapper: wrapper,
            proposedChildIndex: 1,
            draggingTab: n1,
            isCrossWindow: true)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rejected(reason: .crossWindowGroupJoinUnsupported)
        )
    }

    func test_resolver_caseHeaderChildIdx_pinnedRejected() {
        // Pinned tab cannot enter a group via expanded-children drop.
        let wrapper = stubGroupWrapper(token: "A")
        let n1 = stubTab(guid: 1001, token: nil, idxInNormalTabs: 0)
        let ctx = ctxWithWrapperChildIndex(
            wrapper: wrapper,
            proposedChildIndex: 1,
            draggingTab: n1,
            pasteboard: .pinnedTab)
        XCTAssertEqual(
            SidebarGroupDropResolver.resolve(ctx),
            .rejected(reason: .pinnedNotAllowedInGroup)
        )
    }
}
