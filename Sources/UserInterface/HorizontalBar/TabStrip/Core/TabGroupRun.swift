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

/// Render mode for `TabGroupChipView`. The layout engine — not the view —
/// chooses the mode based on the strip's available width vs. the sum of
/// chip full-mode widths, so chip width and tab-width allocation are always
/// derived from the same `baseWidth` calculation.
enum ChipMode {
    /// Color bar + label (+ optional count badge). Width varies with text.
    case full
    /// Color bar + 16pt color swatch only, no label. Fixed 24pt width.
    case compact
}

/// Frame + chosen mode for one chip in a layout pass. Returned by the
/// engine in `chipFrames` keyed by group token; `TabStrip.applyLayout`
/// hands the mode to the chip view via `configure(...)`.
struct ChipPlacement {
    let frame: CGRect
    let mode: ChipMode
}
