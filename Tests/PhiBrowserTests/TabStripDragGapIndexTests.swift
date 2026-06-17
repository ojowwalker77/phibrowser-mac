// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Tail-branch semantics of the drag gap-index resolvers: a drop past
/// every visible item must append after every RECORD, not after the last
/// visible one. Trailing zero-width records (a merged split pair's second
/// pane) sit between the two, and the old `lastVisible.index + 1` landed
/// between the pair's records — invisible on screen (both surfaces merge
/// the pair by partner guid) but persisted into the pinned record order.
@MainActor
final class TabStripDragGapIndexTests: XCTestCase {
    /// Repro shape: pinned records [A, host, secondary] with the pair at
    /// the zone end. A is dragged past the merged cell's right edge.
    func test_cursorGapIndexPastTrailingMergedPairAppendsAfterPair() {
        let controller = TabStripDragController()
        let frames = [
            CGRect(x: 0, y: 0, width: 28, height: 28),   // A (dragged, excluded)
            CGRect(x: 30, y: 0, width: 58, height: 28),  // merged pair host (wide)
            CGRect.zero,                                 // collapsed second pane
        ]

        let index = controller.calculateGapIndex(
            localX: 200,
            tabFrames: frames,
            excludedIndices: [0]
        )

        XCTAssertEqual(index, 3,
            "A drop past the trailing merged pair must append after the pair, not between its records.")
    }

    /// Normal-zone variant: edge-based resolver with the pair at the strip
    /// end and the dragged tab's proxy far to the right.
    func test_edgeBasedGapIndexPastTrailingMergedPairAppendsAfterPair() {
        let controller = TabStripDragController()
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 32),    // dragged tab's slot
            CGRect(x: 102, y: 0, width: 100, height: 32),  // merged pair host
            CGRect.zero,                                   // collapsed second pane
        ]

        let index = controller.calculateGapIndexEdgeBased(
            xFrame: CGRect(x: 400, y: 0, width: 100, height: 32),
            tabFrames: frames,
            chipFrames: [],
            excludedIndex: 0,
            previousIndex: 0
        )

        XCTAssertEqual(index, 3,
            "An edge-based drop past the trailing merged pair must append after the pair, not between its records.")
    }
}
