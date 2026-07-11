// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class PinnedExtensionOrderingTests: XCTestCase {
    private let canonical = [
        PinnedExtensionOrderItem(id: "a", isForcePinned: false),
        PinnedExtensionOrderItem(id: "hidden", isForcePinned: false),
        PinnedExtensionOrderItem(id: "b", isForcePinned: false),
        PinnedExtensionOrderItem(id: "collapsed", isForcePinned: false),
        PinnedExtensionOrderItem(id: "c", isForcePinned: false),
        PinnedExtensionOrderItem(id: "managed", isForcePinned: true),
    ]

    func test_anchoredReorder_forwardMove_preservesOmittedActions() {
        let resolved = PinnedExtensionOrderingEngine.resolve(
            canonical: canonical,
            draggedExtensionId: "a",
            targetExtensionId: "b",
            placement: .after
        )

        XCTAssertEqual(resolved?.items.map(\.id), ["hidden", "b", "a", "collapsed", "c", "managed"])
        XCTAssertEqual(resolved?.destinationIndex, 2)
    }

    func test_anchoredReorder_backwardMove_preservesOmittedActions() {
        let resolved = PinnedExtensionOrderingEngine.resolve(
            canonical: canonical,
            draggedExtensionId: "c",
            targetExtensionId: "b",
            placement: .before
        )

        XCTAssertEqual(resolved?.items.map(\.id), ["a", "hidden", "c", "b", "collapsed", "managed"])
        XCTAssertEqual(resolved?.destinationIndex, 2)
    }

    func test_anchoredReorder_rejectsForcePinnedSourceAndTarget() {
        XCTAssertNil(PinnedExtensionOrderingEngine.resolve(
            canonical: canonical,
            draggedExtensionId: "managed",
            targetExtensionId: "a",
            placement: .before
        ))
        XCTAssertNil(PinnedExtensionOrderingEngine.resolve(
            canonical: canonical,
            draggedExtensionId: "a",
            targetExtensionId: "managed",
            placement: .before
        ))
    }

    func test_anchoredReorder_movesToBeginningAndEndOfUserReorderablePortion() {
        let beginning = PinnedExtensionOrderingEngine.resolve(
            canonical: canonical,
            draggedExtensionId: "c",
            targetExtensionId: "a",
            placement: .before
        )
        XCTAssertEqual(beginning?.items.map(\.id), ["c", "a", "hidden", "b", "collapsed", "managed"])
        XCTAssertEqual(beginning?.destinationIndex, 0)

        let end = PinnedExtensionOrderingEngine.resolve(
            canonical: canonical,
            draggedExtensionId: "a",
            targetExtensionId: "c",
            placement: .after
        )
        XCTAssertEqual(end?.items.map(\.id), ["hidden", "b", "collapsed", "c", "a", "managed"])
        XCTAssertEqual(end?.destinationIndex, 4)
    }

    func test_anchoredReorder_noOpDoesNotEmitMove() {
        let simple = [
            PinnedExtensionOrderItem(id: "a", isForcePinned: false),
            PinnedExtensionOrderItem(id: "b", isForcePinned: false),
            PinnedExtensionOrderItem(id: "c", isForcePinned: false),
        ]
        let resolved = PinnedExtensionOrderingEngine.resolve(
            canonical: simple,
            draggedExtensionId: "b",
            targetExtensionId: "a",
            placement: .after
        )
        XCTAssertEqual(resolved?.items, simple)

        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: simple)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "b",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "a",
            placement: .after,
            surface: .contentHeader
        ))
        XCTAssertNil(engine.commit(surface: .contentHeader))
    }

    func test_previewUsesVisibleProjectionAndDoesNotEmitMove() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)

        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))

        XCTAssertEqual(engine.visiblePresentationOrder, ["b", "a", "c"])
        XCTAssertNil(engine.pendingMove)
    }

    func test_previewRemainsStableWhenPointerFollowsDraggedItem() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))

        // Once the preview becomes [b, a, c], the pointer occupies a's new
        // slot. Repeated hit-testing of that slot must preserve the proposed
        // placement so performDrop can commit it.
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "a",
            placement: .after,
            surface: .contentHeader
        ))

        XCTAssertEqual(engine.visiblePresentationOrder, ["b", "a", "c"])
        XCTAssertEqual(
            engine.commit(surface: .contentHeader),
            PinnedExtensionMoveIntent(extensionId: "a", destinationIndex: 2)
        )
    }

    func test_dropEmitsOneMoveAndWaitsForAuthoritativeSnapshot() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))

        let move = engine.commit(surface: .contentHeader)

        XCTAssertEqual(move, PinnedExtensionMoveIntent(extensionId: "a", destinationIndex: 2))
        XCTAssertEqual(engine.pendingMove, move)
        XCTAssertNil(engine.commit(surface: .contentHeader))
        XCTAssertEqual(engine.visiblePresentationOrder, ["b", "a", "c"])

        engine.reconcile(authoritative: [
            canonical[1], canonical[2], canonical[0], canonical[3], canonical[4], canonical[5],
        ])
        XCTAssertNil(engine.pendingMove)
        XCTAssertEqual(engine.visiblePresentationOrder, [])
    }

    func test_incognitoAndForcePinnedActionsCannotBeginDrag() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)

        XCTAssertFalse(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: false
        ))
        XCTAssertFalse(engine.beginDrag(
            extensionId: "managed",
            visibleProjection: ["a", "b", "c", "managed"],
            surface: .contentHeader,
            allowsReordering: true
        ))
    }

    func test_sidebarAddressBarDrag_isSurfaceLocal() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)

        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .sidebarAddressBar,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .sidebarAddressBar
        ))

        // Another surface cannot preview, clear, cancel, or commit this drag.
        XCTAssertFalse(engine.updatePreview(
            targetExtensionId: "c",
            placement: .after,
            surface: .contentHeader
        ))
        engine.leave(surface: .contentHeader)
        engine.cancel(surface: .contentHeader)
        XCTAssertNil(engine.commit(surface: .contentHeader))

        XCTAssertEqual(engine.visiblePresentationOrder, ["b", "a", "c"])
        XCTAssertEqual(
            engine.commit(surface: .sidebarAddressBar),
            PinnedExtensionMoveIntent(extensionId: "a", destinationIndex: 2)
        )
    }

    func test_sidebarAddressBarCancellation_dropsPreviewWithoutMove() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)

        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .sidebarAddressBar,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "c",
            placement: .after,
            surface: .sidebarAddressBar
        ))

        engine.cancel(surface: .sidebarAddressBar)

        XCTAssertNil(engine.presentationOrder)
        XCTAssertNil(engine.pendingMove)
        XCTAssertNil(engine.commit(surface: .sidebarAddressBar))
    }

    func test_sidebarShelfDrag_isSurfaceLocal() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)

        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .sidebarExtensionShelf,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .sidebarExtensionShelf
        ))

        // Another surface cannot preview, clear, cancel, or commit this drag.
        XCTAssertFalse(engine.updatePreview(
            targetExtensionId: "c",
            placement: .after,
            surface: .sidebarAddressBar
        ))
        engine.leave(surface: .contentHeader)
        engine.cancel(surface: .sidebarAddressBar)
        XCTAssertNil(engine.commit(surface: .contentHeader))

        XCTAssertEqual(engine.visiblePresentationOrder, ["b", "a", "c"])
        XCTAssertEqual(
            engine.commit(surface: .sidebarExtensionShelf),
            PinnedExtensionMoveIntent(extensionId: "a", destinationIndex: 2)
        )
    }

    func test_sidebarShelfCancellation_dropsPreviewWithoutMove() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)

        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .sidebarExtensionShelf,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "c",
            placement: .after,
            surface: .sidebarExtensionShelf
        ))

        engine.cancel(surface: .sidebarExtensionShelf)

        XCTAssertNil(engine.presentationOrder)
        XCTAssertNil(engine.pendingMove)
        XCTAssertNil(engine.commit(surface: .sidebarExtensionShelf))
    }

    // MARK: - Conflict and failed-confirmation recovery

    func test_leavingSurfaceRemovesPreviewAndDropCommitsNothing() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))

        engine.leave(surface: .contentHeader)

        XCTAssertNil(engine.presentationOrder)
        XCTAssertNil(engine.commit(surface: .contentHeader))
    }

    func test_reenteringSameDragAfterLeavingResumesPreview() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))
        engine.leave(surface: .contentHeader)

        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "c",
            placement: .after,
            surface: .contentHeader
        ))

        XCTAssertEqual(engine.visiblePresentationOrder, ["b", "c", "a"])
        XCTAssertEqual(
            engine.commit(surface: .contentHeader),
            PinnedExtensionMoveIntent(extensionId: "a", destinationIndex: 4)
        )
    }

    func test_unchangedSnapshotDuringDragKeepsPreview() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))

        // A snapshot push that changes nothing (e.g. driven by action state)
        // is not a conflict and must not kill the active drag.
        engine.reconcile(authoritative: canonical)

        XCTAssertEqual(engine.visiblePresentationOrder, ["b", "a", "c"])
        XCTAssertEqual(
            engine.commit(surface: .contentHeader),
            PinnedExtensionMoveIntent(extensionId: "a", destinationIndex: 2)
        )
    }

    func test_orderConflictDuringDragCancelsPreviewWithoutRebasing() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))

        // Another window moved "collapsed" ahead of "b": same membership,
        // different authoritative order.
        engine.reconcile(authoritative: [
            canonical[0], canonical[1], canonical[3], canonical[2], canonical[4], canonical[5],
        ])

        XCTAssertNil(engine.presentationOrder)
        XCTAssertFalse(engine.updatePreview(
            targetExtensionId: "c",
            placement: .after,
            surface: .contentHeader
        ))
        XCTAssertNil(engine.commit(surface: .contentHeader))
    }

    func test_membershipConflictDuringDragCancelsPreview() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))

        // "b" was unpinned or unloaded in another window mid-drag.
        engine.reconcile(authoritative: [
            canonical[0], canonical[1], canonical[3], canonical[4], canonical[5],
        ])

        XCTAssertNil(engine.presentationOrder)
        XCTAssertNil(engine.commit(surface: .contentHeader))
    }

    func test_pinFromAnotherWindowDuringDragCancelsPreview() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))

        // Another window pinned a new extension mid-drag: membership grew,
        // appended at the end of the user-reorderable portion.
        engine.reconcile(authoritative: [
            canonical[0], canonical[1], canonical[2], canonical[3], canonical[4],
            PinnedExtensionOrderItem(id: "newly-pinned", isForcePinned: false),
            canonical[5],
        ])

        XCTAssertNil(engine.presentationOrder)
        XCTAssertNil(engine.commit(surface: .contentHeader))
    }

    func test_policyChangeDuringDragCancelsPreview() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))

        // Managed policy force-pinned "c" without changing ids or order.
        engine.reconcile(authoritative: [
            canonical[0], canonical[1], canonical[2], canonical[3],
            PinnedExtensionOrderItem(id: "c", isForcePinned: true),
            canonical[5],
        ])

        XCTAssertNil(engine.presentationOrder)
        XCTAssertNil(engine.commit(surface: .contentHeader))
    }

    func test_differingSnapshotDuringPendingConfirmationReplacesPreview() {
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))
        XCTAssertNotNil(engine.commit(surface: .contentHeader))

        // A concurrent reorder elsewhere produced an order that differs from
        // the pending preview; it wins immediately.
        engine.reconcile(authoritative: [
            canonical[4], canonical[0], canonical[1], canonical[2], canonical[3], canonical[5],
        ])

        XCTAssertNil(engine.pendingMove)
        XCTAssertNil(engine.presentationOrder)
    }

    func test_watchdogAbandonsUnconfirmedDropAndRequestsSnapshotRefresh() {
        let engine = PinnedExtensionOrderingEngine(confirmationTimeout: 0.05)
        let refreshRequested = expectation(description: "snapshot refresh requested")
        engine.onConfirmationTimeout = { refreshRequested.fulfill() }
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))
        XCTAssertNotNil(engine.commit(surface: .contentHeader))

        wait(for: [refreshRequested], timeout: 2)

        XCTAssertNil(engine.pendingMove)
        XCTAssertNil(engine.presentationOrder)
    }

    func test_confirmationBeforeTimeoutDisarmsWatchdog() {
        let engine = PinnedExtensionOrderingEngine(confirmationTimeout: 0.05)
        let timedOut = expectation(description: "watchdog fired")
        timedOut.isInverted = true
        engine.onConfirmationTimeout = { timedOut.fulfill() }
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))
        XCTAssertNotNil(engine.commit(surface: .contentHeader))

        engine.reconcile(authoritative: [
            canonical[1], canonical[2], canonical[0], canonical[3], canonical[4], canonical[5],
        ])

        wait(for: [timedOut], timeout: 0.3)
    }

    func test_newDragDisarmsPreviousUnconfirmedWatchdog() {
        let engine = PinnedExtensionOrderingEngine(confirmationTimeout: 0.05)
        let timedOut = expectation(description: "watchdog fired")
        timedOut.isInverted = true
        engine.onConfirmationTimeout = { timedOut.fulfill() }
        engine.reconcile(authoritative: canonical)
        XCTAssertTrue(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "b",
            placement: .after,
            surface: .contentHeader
        ))
        XCTAssertNotNil(engine.commit(surface: .contentHeader))

        // The user starts a second drag while the first drop is still
        // unconfirmed; the stale watchdog must not fire into the new drag.
        XCTAssertTrue(engine.beginDrag(
            extensionId: "b",
            visibleProjection: ["a", "b", "c"],
            surface: .contentHeader,
            allowsReordering: true
        ))

        wait(for: [timedOut], timeout: 0.3)
        XCTAssertTrue(engine.updatePreview(
            targetExtensionId: "c",
            placement: .after,
            surface: .contentHeader
        ))
    }

    func test_sidebarAnchorResolution_coversFirstMiddleLastAndInvalidPointer() {
        // 24 pt buttons with 2 pt spacing: frames 0–24, 26–50, 52–76.
        let slots = [
            SideAddressBar.ExtensionReorderSlot(id: "a", midX: 12),
            SideAddressBar.ExtensionReorderSlot(id: "b", midX: 38),
            SideAddressBar.ExtensionReorderSlot(id: "c", midX: 64),
        ]

        let cases: [(x: CGFloat, targetId: String, placement: PinnedExtensionAnchorPlacement)] = [
            (-10, "a", .before), // ahead of the leading edge clamps to the first slot
            (5, "a", .before),
            (13, "a", .after),
            (30, "b", .before), // inside the gap resolves to the nearest midpoint
            (40, "b", .after),
            (60, "c", .before),
            (200, "c", .after), // past the trailing edge clamps to the last slot
        ]
        for testCase in cases {
            let anchor = SideAddressBar.extensionReorderAnchor(atX: testCase.x, slots: slots)
            XCTAssertEqual(anchor?.targetId, testCase.targetId, "x=\(testCase.x)")
            XCTAssertEqual(anchor?.placement, testCase.placement, "x=\(testCase.x)")
        }

        XCTAssertNil(SideAddressBar.extensionReorderAnchor(atX: 12, slots: []))
    }

    func test_shelfAnchorResolution_coversRowMajorGridCases() {
        // 30×28 pt cells in a 3-column grid with 8 pt spacing and insets:
        // row 0 (y 8–36): a (x 8–38), b (x 46–76), c (x 84–114)
        // row 1 (y 44–72): d (x 8–38), e (x 46–76)
        func slot(_ id: String, column: Int, row: Int) -> PinnedTabViewController.ExtensionReorderSlot {
            PinnedTabViewController.ExtensionReorderSlot(
                id: id,
                frame: CGRect(x: 8 + column * 38, y: 8 + row * 36, width: 30, height: 28)
            )
        }
        let slots = [
            slot("a", column: 0, row: 0),
            slot("b", column: 1, row: 0),
            slot("c", column: 2, row: 0),
            slot("d", column: 0, row: 1),
            slot("e", column: 1, row: 1),
        ]

        let cases: [(point: CGPoint, targetId: String, placement: PinnedExtensionAnchorPlacement)] = [
            (CGPoint(x: 2, y: 22), "a", .before), // beginning clamps ahead of the first action
            (CGPoint(x: 60, y: 30), "b", .before), // middle, ahead of b's midpoint
            (CGPoint(x: 70, y: 22), "b", .after), // middle, past b's midpoint
            (CGPoint(x: 140, y: 22), "c", .after), // row end clamps past the last action of row 0
            (CGPoint(x: 20, y: 58), "d", .before), // cross-row: row 1 resolves independently
            (CGPoint(x: 30, y: 39), "a", .after), // row gap resolves to the nearer row 0
            (CGPoint(x: 30, y: 41), "d", .after), // crossing the row midpoint flips to row 1
            (CGPoint(x: 140, y: 58), "e", .after), // overall end: past the last action of the grid
        ]
        for testCase in cases {
            let anchor = PinnedTabViewController.extensionReorderAnchor(at: testCase.point, slots: slots)
            XCTAssertEqual(anchor?.targetId, testCase.targetId, "point=\(testCase.point)")
            XCTAssertEqual(anchor?.placement, testCase.placement, "point=\(testCase.point)")
        }

        // Outside the shelf rows' vertical band the pointer is over another
        // sidebar region (address bar above, pinned-tab grid below): no anchor.
        XCTAssertNil(PinnedTabViewController.extensionReorderAnchor(
            at: CGPoint(x: 20, y: 1), slots: slots))
        XCTAssertNil(PinnedTabViewController.extensionReorderAnchor(
            at: CGPoint(x: 20, y: 90), slots: slots))
        XCTAssertNil(PinnedTabViewController.extensionReorderAnchor(
            at: CGPoint(x: 20, y: 22), slots: []))
    }

    func test_shelfAnchorResolution_extendsEndPlacementDownToTheTrailingLimit() {
        // Same grid as above: row 1 (y 44–72) holds d (x 8–38) and e (x 46–76).
        // The strip below the last row, down to the first pinned tab's midline
        // (here 86), still anchors to the last row so end placement does not
        // demand pixel precision; past the limit the drag is over the tab grid.
        func slot(_ id: String, column: Int, row: Int) -> PinnedTabViewController.ExtensionReorderSlot {
            PinnedTabViewController.ExtensionReorderSlot(
                id: id,
                frame: CGRect(x: 8 + column * 38, y: 8 + row * 36, width: 30, height: 28)
            )
        }
        let slots = [
            slot("a", column: 0, row: 0),
            slot("b", column: 1, row: 0),
            slot("c", column: 2, row: 0),
            slot("d", column: 0, row: 1),
            slot("e", column: 1, row: 1),
        ]

        // The reported miss: aiming right of and a little below the last
        // row's final action resolves to overall-end instead of rejecting.
        let overallEnd = PinnedTabViewController.extensionReorderAnchor(
            at: CGPoint(x: 140, y: 80), slots: slots, trailingLimit: 86)
        XCTAssertEqual(overallEnd?.targetId, "e")
        XCTAssertEqual(overallEnd?.placement, .after)

        let belowFirstColumn = PinnedTabViewController.extensionReorderAnchor(
            at: CGPoint(x: 20, y: 84), slots: slots, trailingLimit: 86)
        XCTAssertEqual(belowFirstColumn?.targetId, "d")
        XCTAssertEqual(belowFirstColumn?.placement, .before)

        // Past the limit is the pinned-tab grid; above the first row stays
        // strict regardless of the limit.
        XCTAssertNil(PinnedTabViewController.extensionReorderAnchor(
            at: CGPoint(x: 20, y: 90), slots: slots, trailingLimit: 86))
        XCTAssertNil(PinnedTabViewController.extensionReorderAnchor(
            at: CGPoint(x: 20, y: 1), slots: slots, trailingLimit: 86))
    }

    func test_interleavedForcePinnedAuthoritativeDisablesDragEntirely() {
        // Policy force-pinned an action the user had already pinned: it stays
        // at its pref position instead of joining the trailing suffix. No
        // anchored move can resolve against that shape, so the gesture must
        // stay a plain click rather than a drag whose every preview fails.
        let engine = PinnedExtensionOrderingEngine()
        engine.reconcile(authoritative: [
            PinnedExtensionOrderItem(id: "managed", isForcePinned: true),
            PinnedExtensionOrderItem(id: "a", isForcePinned: false),
            PinnedExtensionOrderItem(id: "b", isForcePinned: false),
        ])

        XCTAssertFalse(engine.beginDrag(
            extensionId: "a",
            visibleProjection: ["managed", "a", "b"],
            surface: .contentHeader,
            allowsReordering: true
        ))
        XCTAssertNil(engine.presentationOrder)
    }

    func test_headerAnchorResolution_coversFirstMiddleLastAndClamps() {
        // 24 pt icon columns on a 26 pt stride: columns 0–24, 26–50, 52–76;
        // midpoints 12, 38, 64.
        let ids = ["a", "b", "c"]

        let cases: [(x: CGFloat, targetId: String, placement: PinnedExtensionAnchorPlacement)] = [
            (0, "a", .before),
            (11, "a", .before),
            (13, "a", .after),
            (25, "a", .after), // a spacing gap belongs to the column on its left
            (30, "b", .before),
            (40, "b", .after),
            (60, "c", .before),
            (76, "c", .after),
            (200, "c", .after), // past the trailing edge clamps to the last slot
        ]
        for testCase in cases {
            let anchor = HeaderExtensionReorderView.reorderAnchor(atX: testCase.x, orderedIds: ids)
            XCTAssertEqual(anchor?.targetId, testCase.targetId, "x=\(testCase.x)")
            XCTAssertEqual(anchor?.placement, testCase.placement, "x=\(testCase.x)")
        }

        XCTAssertNil(HeaderExtensionReorderView.reorderAnchor(atX: 12, orderedIds: []))
    }

    func test_headerSlotResolution_identifiesPressedIconAndRejectsGaps() {
        XCTAssertEqual(HeaderExtensionReorderView.slotIndex(atX: 0, slotCount: 3), 0)
        XCTAssertEqual(HeaderExtensionReorderView.slotIndex(atX: 24, slotCount: 3), 0)
        XCTAssertNil(HeaderExtensionReorderView.slotIndex(atX: 25, slotCount: 3)) // spacing gap
        XCTAssertEqual(HeaderExtensionReorderView.slotIndex(atX: 26, slotCount: 3), 1)
        XCTAssertEqual(HeaderExtensionReorderView.slotIndex(atX: 76, slotCount: 3), 2)
        XCTAssertNil(HeaderExtensionReorderView.slotIndex(atX: 80, slotCount: 3)) // past the row
        XCTAssertNil(HeaderExtensionReorderView.slotIndex(atX: -1, slotCount: 3))
        XCTAssertNil(HeaderExtensionReorderView.slotIndex(atX: 10, slotCount: 0))
    }

    func test_extensionSnapshotParsesForcePinnedState() {
        let extensionModel = Extension(from: [
            "id": "managed",
            "name": "Managed Extension",
            "version": "1.0",
            "isPinned": true,
            "pinnedIndex": 0,
            "isForcePinned": true,
        ])

        XCTAssertTrue(extensionModel.isForcePinned)
    }
}
