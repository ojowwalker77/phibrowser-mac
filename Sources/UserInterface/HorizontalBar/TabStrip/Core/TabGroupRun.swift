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

/// Frame for one chip in a layout pass. Returned by the engine in
/// `chipFrames` keyed by group token; `TabStrip.applyLayout` applies
/// the frame to the chip view.
struct ChipPlacement {
    let frame: CGRect
}
