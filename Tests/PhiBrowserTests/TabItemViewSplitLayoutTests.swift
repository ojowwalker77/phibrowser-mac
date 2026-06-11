// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Layout-mode selection for split-merged cells: below
/// `splitCompactModeThreshold` (2x the single-tab cutoff) the cell must
/// fall back to the centered two-favicon compact rendering. In the
/// 64-128pt band the per-pane normal layout has no room — hover close
/// buttons land on top of the pane favicons, so a click meant to focus
/// a pane closes it instead.
@MainActor
final class TabItemViewSplitLayoutTests: XCTestCase {
    private func makeMergedSplitView(width: CGFloat, partner: Tab) -> TabItemView {
        let view = TabItemView()
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Primary",
            url: "https://example.com",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            pinnedSplitPartner: partner,
            sourceTab: nil
        ))
        view.frame = CGRect(x: 0, y: 0, width: width, height: TabStripMetrics.Strip.tabHeight)
        view.layout()
        return view
    }

    private func visibleFrames(of view: TabItemView) -> [CGRect] {
        view.subviews
            .filter { !$0.isHidden && !$0.frame.isEmpty }
            .map(\.frame)
            .sorted { $0.minX < $1.minX }
    }

    func test_mergedSplitCellBelowSplitThresholdShowsOnlyCenteredFaviconPair() {
        let partner = Tab(guid: 2, url: "https://partner.example", isActive: false, index: 1)
        let view = makeMergedSplitView(width: 100, partner: partner)

        let frames = visibleFrames(of: view)
        let faviconSize = TabStripMetrics.Content.faviconSize
        XCTAssertEqual(frames.count, 2,
            "A merged split cell narrower than the split compact threshold must show only the two pane favicons.")
        // 16 + 2 + 16 pair centered in the 100pt cell -> x = 33 and 51.
        XCTAssertEqual(frames[0], CGRect(x: 33, y: 8, width: faviconSize.width, height: faviconSize.height))
        XCTAssertEqual(frames[1], CGRect(x: 51, y: 8, width: faviconSize.width, height: faviconSize.height))
    }

    func test_mergedSplitCellAboveSplitThresholdRendersPerPaneLayout() {
        let partner = Tab(guid: 2, url: "https://partner.example", isActive: false, index: 1)
        let view = makeMergedSplitView(width: 140, partner: partner)

        let frames = visibleFrames(of: view)
        let faviconSize = TabStripMetrics.Content.faviconSize
        XCTAssertTrue(frames.contains(CGRect(x: 6, y: 8, width: faviconSize.width, height: faviconSize.height)),
            "Left pane favicon must sit at its leading position in normal mode.")
        XCTAssertTrue(frames.contains(CGRect(x: 76, y: 8, width: faviconSize.width, height: faviconSize.height)),
            "Right pane favicon must sit at its leading position past the cell midpoint.")
        XCTAssertTrue(frames.contains { $0.size == TabStripMetrics.Content.separatorSize },
            "The split divider must be visible in normal mode.")
    }

    /// Couples the strip's active-split width floor to the render
    /// threshold: at `Tab.activeSplitMinWidth` (what the layout engine
    /// allocates to a focused merged cell under pressure) the cell must
    /// still render the per-pane layout, not the compact favicon pair.
    func test_mergedSplitCellAtActiveSplitMinWidthRendersPerPaneLayout() {
        let partner = Tab(guid: 2, url: "https://partner.example", isActive: false, index: 1)
        let view = makeMergedSplitView(width: TabStripMetrics.Tab.activeSplitMinWidth, partner: partner)

        let frames = visibleFrames(of: view)
        let faviconSize = TabStripMetrics.Content.faviconSize
        XCTAssertTrue(frames.contains(CGRect(x: 6, y: 8, width: faviconSize.width, height: faviconSize.height)),
            "At the active-split width floor the left pane favicon must sit at its leading position.")
        XCTAssertTrue(frames.contains { $0.size == TabStripMetrics.Content.separatorSize },
            "At the active-split width floor the cell must keep the per-pane layout (divider visible).")
    }

    func test_singleTabKeepsSingleTabCompactThreshold() {
        let view = TabItemView()
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Single",
            url: "https://example.com",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            sourceTab: nil
        ))
        view.frame = CGRect(x: 0, y: 0, width: 100, height: TabStripMetrics.Strip.tabHeight)
        view.layout()

        let frames = visibleFrames(of: view)
        let faviconSize = TabStripMetrics.Content.faviconSize
        XCTAssertTrue(frames.contains(CGRect(x: 6, y: 8, width: faviconSize.width, height: faviconSize.height)),
            "A 100pt single tab must keep the leading favicon (normal mode), not the centered compact layout.")
    }
}
