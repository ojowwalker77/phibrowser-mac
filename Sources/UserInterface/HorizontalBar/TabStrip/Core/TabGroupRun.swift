// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// A contiguous run of grouped tabs in a window's normal-tab list. Built by
/// `TabStrip.currentGroupRuns()` from `BrowserState.normalTabs` (each run
/// is a maximal stretch of adjacent tabs sharing the same `groupToken`).
/// Consumed by `TabStripLayoutEngine.layoutNormal` to reserve chip space
/// and emit underline rects.
///
/// `range` indexes into the input `tabs` array passed to the engine; it is
/// inclusive on both ends. The engine never holds onto runs beyond the
/// scope of one layout pass, so live-token churn is irrelevant here.
struct GroupRun {
    let token: String
    let range: ClosedRange<Int>
    let isCollapsed: Bool
}

/// Frame + right-separator info for one chip in a layout pass.
/// Returned by the engine in `chipFrames` keyed by group token;
/// `TabStrip.applyLayout` applies the frame to the chip view and
/// renders the separator via `updateChipRightSeparators`.
struct ChipPlacement {
    let frame: CGRect
    /// X for the separator between chip and its right neighbor in
    /// flow (tab[run.lowerBound] when expanded, or tab[run.upperBound+1]
    /// when collapsed). Nil when there is no right neighbor (chip at
    /// strip end, chip is excluded during whole-group drag, or the
    /// neighbor is the single-tab drag-excluded tab).
    let rightSeparatorX: CGFloat?
    /// Tab index whose active/hovered state hides the right separator
    /// (same rule as tab↔tab separators). Paired with `rightSeparatorX`;
    /// nil when `rightSeparatorX` is nil.
    let rightSeparatorNeighborIndex: Int?
}
