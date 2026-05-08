// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Frame of one tab-group chip on the strip, used by drag hit testing.
struct TabStripChipFrame {
    /// Hex token of the chip's group.
    let token: String
    /// First member's index in `normalTabs` — used to map cursor-on-chip
    /// to the leading-edge gap target.
    let firstMemberIndex: Int
    /// Last member's index in `normalTabs` — used by the trailing-edge
    /// auto-leave gate to find the group's right boundary frame in
    /// `normalTabFrames`.
    let lastMemberIndex: Int
    /// Chip frame in normalContainer coordinates with scroll offset
    /// already added back in (matching `normalTabFrames`).
    let frame: CGRect
}

/// Geometry snapshot used during tab dragging.
struct TabStripMetricsSnapshot {
    /// Pinned container frame in tab-strip coordinates.
    let pinnedContainerFrame: CGRect
    /// Normal container frame in tab-strip coordinates.
    let normalContainerFrame: CGRect
    /// Fixed width for pinned tabs.
    let pinnedTabWidth: CGFloat
    /// Current normal-tab frames in container coordinates.
    let normalTabFrames: [CGRect]
    /// Current pinned-tab frames in container coordinates.
    let pinnedTabFrames: [CGRect]
    /// Horizontal scroll offset applied to normal tabs.
    let normalScrollOffset: CGFloat
    /// Visible group chips on the normal strip.
    let chipFrames: [TabStripChipFrame]
    /// Currently rendered drag-proxy frame in normalContainer
    /// coordinates (same space as `normalTabFrames`). Nil when the
    /// proxy isn't over the normal zone (e.g. proxy is in pinned
    /// zone). Used by the controller's group-trailing hit testing
    /// so thresholds key off the visible tab edges rather than the
    /// cursor (which can sit anywhere within the dragged tab,
    /// depending on where the user grabbed it).
    let draggedTabFrameInNormal: CGRect?
}

/// Delegate for drag-driven tab-strip updates.
protocol TabStripDragDelegate: AnyObject {
    /// Requests a relayout after the drag gap changes.
    /// - Parameters:
    ///   - pinnedExcludedIndex: Source tab index to hide in the pinned zone.
    ///   - pinnedGapIndex: Gap position in the pinned zone.
    ///   - normalExcludedIndex: Source tab index to hide in the normal zone.
    ///   - normalGapIndex: Gap position in the normal zone.
    ///   - normalGapWidth: Gap width for the normal zone.
    func dragControllerDidUpdateLayout(
        pinnedExcludedIndex: Int?,
        pinnedGapIndex: Int?,
        normalExcludedIndex: Int?,
        normalGapIndex: Int?,
        normalGapWidth: CGFloat?
    )

    /// Returns current container geometry for hit testing.
    func dragControllerRequestMetrics() -> TabStripMetricsSnapshot

    /// Commits the final tab move when dragging ends.
    /// - Parameters:
    ///   - tab: Dragged tab.
    ///   - toZone: Destination zone.
    ///   - toIndex: Destination index.
    func dragControllerDidEndDrag(
        tab: Tab,
        toZone: TabContainerType,
        toIndex: Int
    )

    /// Cancels the drag and restores the original layout.
    func dragControllerDidCancelDrag()

    /// Converts a window point into local tab-strip coordinates.
    func dragControllerConvertPointToLocal(_ windowPoint: CGPoint) -> CGPoint
}

final class TabStripDragController {
    weak var delegate: TabStripDragDelegate?

    /// Active drag context, or `nil` when idle.
    private(set) var context: TabDragContext?

    /// Whether a drag is currently active.
    var isDragging: Bool {
        context != nil
    }

    // MARK: - Start Dragging

    /// Starts a drag operation.
    /// - Parameters:
    ///   - tab: Dragged tab.
    ///   - sourceIndex: Source index.
    ///   - sourceZone: Source zone.
    ///   - mouseLocation: Mouse location in tab-strip coordinates.
    ///   - tabFrame: Tab frame in container coordinates.
    func startDragging(
        tab: Tab,
        sourceIndex: Int,
        sourceZone: TabContainerType,
        mouseLocation: CGPoint,
        tabFrame: CGRect
    ) {
        // Capture the source geometry before any layout changes.
        context = TabDragContext(
            draggingTab: tab,
            sourceContainerType: sourceZone,
            sourceIndex: sourceIndex,
            initialMouseLocation: mouseLocation,
            initialTabFrame: tabFrame
        )

        // Hide the source tab before the gap is shown.
        notifyLayoutUpdate()
    }

    // MARK: - Update Dragging

    /// Updates the drag location.
    /// - Parameter mouseLocation: Current mouse location in tab-strip coordinates.
    func updateDragging(mouseLocation: CGPoint) {
        guard let context = context else { return }

        // Keep the latest pointer position for hit testing.
        context.currentMouseLocation = mouseLocation

        // Query the latest layout geometry from the delegate.
        guard let metrics = delegate?.dragControllerRequestMetrics() else { return }

        // Resolve the destination zone and raw gap index. Normal-zone
        // uses edge-based hit testing with hysteresis (see
        // `calculateGapIndexEdgeBased`), giving consistent gap-flip
        // behavior across every tab transition.
        let (targetZone, rawTargetIndex) = calculateTarget(
            mouseLocation: mouseLocation,
            metrics: metrics,
            context: context
        )

        // First-member-of-own-group override: when D is the first
        // member of its own group (excluded at firstMemberIndex), no
        // visible tab sits at firstMemberIndex, so edge-based hit
        // testing can never return targetIndex = firstMemberIndex.
        // Without that, the layout engine's `gapBeforeRunStartChip`
        // flag has nowhere to apply (it only takes effect when
        // gapAtIndex equals run.lowerBound). The chip then can't
        // slide right to reveal a "drop right before chip" slot.
        //
        // Override: when D 50% covers its own chip (chip.midX inside
        // D's frame), force targetIndex = sourceIndex. The layout
        // then renders gap-before-chip and the user sees a drop slot
        // appear adjacent to the chip's leading edge. Combined with
        // leadingLeaveToken (also gated on the same threshold),
        // releasing here commits as "leave T at source position".
        let targetIndex: Int = {
            guard targetZone == .normal,
                  let token = context.draggingTab.groupToken,
                  let chip = metrics.chipFrames.first(where: { $0.token == token }),
                  context.sourceContainerType == .normal,
                  context.sourceIndex == chip.firstMemberIndex,
                  let xFrame = metrics.draggedTabFrameInNormal,
                  xFrame.minX <= chip.frame.midX else { return rawTargetIndex }
            return context.sourceIndex
        }()

        // Cursor x in normalContainer space — used by the chip
        // step-aside decision and leading-join gate that still key
        // off cursor for non-own-group chips.
        let cursorInContainer: CGFloat = {
            guard targetZone == .normal else { return 0 }
            let localPoint = delegate?.dragControllerConvertPointToLocal(mouseLocation) ?? mouseLocation
            return localPoint.x
                - metrics.normalContainerFrame.minX
                + metrics.normalScrollOffset
        }()

        // Resolve the chip (if any) whose run starts at the gap
        // target. Both the gap-side decision and the leading-edge
        // join detection key off this.
        let leadingChip: TabStripChipFrame? = (targetZone == .normal)
            ? metrics.chipFrames.first(where: { $0.firstMemberIndex == targetIndex })
            : nil

        // gapBeforeChip — visual gap placement relative to a chip.
        // Drives `gapBeforeRunStartChip` in the layout engine, which
        // only takes effect when `gapAtIndex == run.lowerBound`.
        //
        // Three resolution paths:
        //   1. `leadingChip` is non-nil (= targetIndex matches some
        //      chip's firstMemberIndex). The relevant chip is
        //      `leadingChip` itself; we use its frame and apply the
        //      own-vs-foreign threshold.
        //   2. `leadingChip` is nil AND D is its own group's first
        //      member. This is the special case where edge-based hit
        //      testing can't return targetIndex = firstMemberIndex
        //      (D is excluded there). The first-member override
        //      above is the primary fix; this branch is the visual
        //      fallback for the same scenario.
        //   3. Otherwise: no chip-let-way applies. Return false.
        //
        // Threshold per chip identity. Always compares D's *leading*
        // edge against chip's current midX — "leading edge crosses
        // chip center" = 50% cover triggers let-way, matching the
        // same mental model as tab-tab let-way.
        //
        //   • Own chip: `D.minX <= chip.midX` (one-sided, going-
        //     leftward only — own-chip let-way is the "leave T"
        //     intent, which by definition is leftward).
        //
        //   • Foreign chip: prev-state hysteresis (mirrors the
        //     calculateGapIndexEdgeBased pattern):
        //       - was "before chip" (chip slid right):
        //         forward going-right flips iff `D.maxX >= chip.midX`.
        //       - was "after chip" (chip natural):
        //         backward going-left flips iff `D.minX <= chip.midX`.
        //     Without prev-state branching, a single rule using only
        //     D.maxX would fail symmetric scenarios: when D enters
        //     T's leading from the RIGHT (after dragging through the
        //     whole group), `D.maxX < chip.midX` requires D to be
        //     entirely past chip on the left — way too late, so
        //     leadingJoin keeps firing all the way down to chip.
        //     The minX-on-left-going branch fires at the natural
        //     "D's left edge meets chip center" moment.
        let gapBeforeChip: Bool = {
            // Path 1: leadingChip set.
            if let chip = leadingChip {
                guard let xFrame = metrics.draggedTabFrameInNormal else {
                    return cursorInContainer < chip.frame.midX
                }
                if chip.token == context.draggingTab.groupToken {
                    return xFrame.minX <= chip.frame.midX
                }
                if context.gapBeforeRunStartChip {
                    // Was "before chip" — chip currently slid right.
                    // Forward flip when D's right edge crosses
                    // (slid) chip.midX going right.
                    return xFrame.maxX < chip.frame.midX
                } else {
                    // Was "after chip" — chip currently natural.
                    // Backward flip when D's left edge crosses
                    // (natural) chip.midX going left.
                    return xFrame.minX <= chip.frame.midX
                }
            }
            // Path 2: leadingChip nil + D = own group's first member.
            if let token = context.draggingTab.groupToken,
               let ownChip = metrics.chipFrames.first(where: { $0.token == token }),
               context.sourceContainerType == .normal,
               context.sourceIndex == ownChip.firstMemberIndex,
               let xFrame = metrics.draggedTabFrameInNormal {
                return xFrame.minX <= ownChip.frame.midX
            }
            return false
        }()

        // Leading-edge auto-JOIN: track `gapBeforeChip` directly so
        // visual and commit are aligned by construction.
        //
        //   gap-before-chip → drop slot OUTSIDE T's color → no join.
        //   gap-after-chip  → drop slot INSIDE T's color  → join.
        //
        // Earlier attempt used "D 50% covers m_first" but that fires
        // too late: chip sits to the LEFT of m_first by chip_w +
        // spacing + tab_width/2, so the visual let-way of chip
        // (gap-after-chip) happens well before D's right edge
        // reaches m_first's center. Tracking `gapBeforeChip` makes
        // them flip together.
        //
        // `leadingChip` non-nil is implicit in `!gapBeforeChip`
        // having any meaning — when leadingChip is nil, gapBeforeChip
        // is false but no chip-related drop is in progress; we still
        // require chip != own and leadingChip non-nil to fire join.
        let leadingJoinToken: String? = {
            guard let chip = leadingChip,
                  chip.token != context.draggingTab.groupToken,
                  !gapBeforeChip else { return nil }
            return chip.token
        }()

        // Leading-edge LEAVE: D in T, D 50% covers T's chip
        // (chip.midX inside D's frame; from leftward approach
        // x.minX <= chip.midX is the active half of the rule). The
        // chip is small enough that "fully past chip" would need
        // very little additional travel beyond 50% covers, so we
        // collapse let-way and leave into the same threshold —
        // visual chip-slide and commit-leave agree exactly.
        // Hysteresis is implicit via chip's current frame: once
        // gapBeforeChip flips on, chip slides right by gap_width,
        // shifting chip.midX higher; D must retreat past that
        // higher midX to flip back.
        let leadingLeaveToken: String? = {
            guard let token = context.draggingTab.groupToken,
                  let chip = metrics.chipFrames.first(where: { $0.token == token }),
                  let xFrame = metrics.draggedTabFrameInNormal,
                  xFrame.minX <= chip.frame.midX else { return nil }
            return token
        }()

        // Trailing-edge LEAVE: when the dragged tab is in some group
        // AND x has cleared past z entirely (no horizontal overlap),
        // the user is leaving via the trailing edge.
        //
        // Threshold: `x.minX > z.maxX` in the post-let-way layout.
        // Once let-way fires, z snaps to its source-hole position
        // and z.maxX is fixed at `x4 + tab_width`. Leave triggers
        // only after x has fully crossed past that point — giving
        // the user a clear "x has moved past z" signal that's
        // independent of where they grabbed inside x.
        //
        // Before let-way fires (gap-before-z state, z shifted right
        // by gap_width), z.maxX is `x4 + gap_width + tab_width`.
        // x.minX > that is also a valid leave signal: it means x
        // has cleared past z's currently-rendered right edge. So
        // we use `x.minX > zFrame.maxX` directly with the current
        // zFrame, regardless of which state we're in. Hysteresis
        // is implicit: in gap-before-z state z is rightward, so
        // leaving requires more drag distance — the gap-flip-to-
        // after-z transition typically fires first and shrinks the
        // threshold.
        //
        // Fallbacks:
        //  • Dragged tab is itself the run's last member — anchor
        //    on the member before it (post-exclusion visible last).
        //  • Single-member group with the only member being the
        //    dragged one — leadingLeave handles it.
        //
        // The geometric counterpart (`toIndex > upperBound + 1`)
        // still kicks in further right and remains a safety net.
        let trailingLeaveToken: String? = {
            guard let token = context.draggingTab.groupToken,
                  let chip = metrics.chipFrames.first(where: { $0.token == token }),
                  let xFrame = metrics.draggedTabFrameInNormal
                  else { return nil }
            let isOwnGroupLastMember = (context.sourceContainerType == .normal
                && context.sourceIndex == chip.lastMemberIndex)
            let visibleLastIndex = isOwnGroupLastMember
                ? chip.lastMemberIndex - 1
                : chip.lastMemberIndex
            guard visibleLastIndex >= chip.firstMemberIndex,
                  visibleLastIndex < metrics.normalTabFrames.count else { return nil }
            let zFrame = metrics.normalTabFrames[visibleLastIndex]
            guard zFrame != .zero else { return nil }
            guard xFrame.minX > zFrame.maxX else { return nil }
            return token
        }()

        // Trailing-edge auto-JOIN: D not in some group T, AND D's
        // post-move position would land at T's upperBound+1 (right
        // after z) AND D covers z by at least 1/3 of z's width →
        // drop intent is "join T as new last".
        //
        // The 1/3 threshold (instead of 50%) gives the from-right
        // approach a real "join T" zone. From-right, the toIndex
        // flip from upperBound+1 to upperBound happens at 50%
        // cover (= D.minX <= z.midX); a 50% trailingJoin threshold
        // would coincide with the flip and never have a window of
        // its own. With 1/3, the from-right zone is
        // `(z.midX, z.maxX - tab_w/3]` — narrow but distinct:
        //   • cover < 1/3 → drop slot still after T, ungrouped.
        //   • cover in [1/3, 1/2) → join T as new last.
        //   • cover ≥ 1/2 → toIndex flips, sandwich joins as
        //     second-to-last.
        //
        // From-left, the zone widens naturally: trailingJoin fires
        // the moment toIndex reaches upperBound+1 (entry cover is
        // 50%, well over 1/3) and stays active through D crossing
        // z until cover drops below 1/3 on the right side.
        //
        // Why post-move position, not raw `targetIndex`?
        // `calculateGapIndexEdgeBased` returns `item.index` from
        // visibleFrames, which excludes D. When D's source sits
        // exactly at `chip.lastMemberIndex+1` (= D is right next
        // to T's trailing edge, e.g., a normal tab between two
        // groups), the loop never returns the value
        // `chip.lastMemberIndex+1` — that index belongs to D and
        // is excluded. The next visible tab after D yields a
        // higher index (here `chip.lastMemberIndex+2`), giving
        // `targetIndex = sourceIndex+1` (the no-op state).
        // Computing post-move position
        // (`(source < target) ? target-1 : target`) collapses
        // both representations of "drop at chip.lastMemberIndex+1"
        // — when D's source IS that slot AND when the slot is
        // visible — into a single check.
        let trailingJoinToken: String? = {
            guard let xFrame = metrics.draggedTabFrameInNormal else { return nil }
            let postMoveIdx = (context.sourceContainerType == .normal
                && context.sourceIndex < targetIndex)
                ? targetIndex - 1
                : targetIndex
            for chip in metrics.chipFrames where chip.token != context.draggingTab.groupToken {
                guard postMoveIdx == chip.lastMemberIndex + 1,
                      chip.lastMemberIndex >= 0,
                      chip.lastMemberIndex < metrics.normalTabFrames.count else { continue }
                let zFrame = metrics.normalTabFrames[chip.lastMemberIndex]
                guard zFrame != .zero, zFrame.width > 0 else { continue }
                let third = zFrame.width / 3
                // 1/3 cover: D's overlap with z is at least 1/3 of
                // z's width. Equivalently, D.maxX has crossed
                // `z.minX + tab_w/3` from the left AND D.minX
                // hasn't yet crossed `z.maxX - tab_w/3` from the
                // right.
                guard xFrame.maxX >= zFrame.minX + third,
                      xFrame.minX <= zFrame.maxX - third else { continue }
                return chip.token
            }
            return nil
        }()

        // Update the drag target state.
        let changed = context.targetContainerType != targetZone
            || context.targetIndex != targetIndex
            || context.gapBeforeRunStartChip != gapBeforeChip
            || context.targetGroupForLeadingJoin != leadingJoinToken
            || context.targetGroupForLeadingLeave != leadingLeaveToken
            || context.targetGroupForTrailingLeave != trailingLeaveToken
            || context.targetGroupForTrailingJoin != trailingJoinToken
        context.targetContainerType = targetZone
        context.targetIndex = targetIndex
        context.gapBeforeRunStartChip = gapBeforeChip
        context.targetGroupForLeadingJoin = leadingJoinToken
        context.targetGroupForLeadingLeave = leadingLeaveToken
        context.targetGroupForTrailingLeave = trailingLeaveToken
        context.targetGroupForTrailingJoin = trailingJoinToken

        // Only relayout when the destination actually changes.
        if changed {
            notifyLayoutUpdate()
        }
    }

    // MARK: - End Dragging

    /// Ends the drag and optionally commits the move.
    func endDragging(force: Bool = false) {
        guard let context = context else { return }

        if force || context.hasPositionChanged {
            // Commit the move once the destination is final.
            delegate?.dragControllerDidEndDrag(
                tab: context.draggingTab,
                toZone: context.targetContainerType,
                toIndex: context.targetIndex
            )
        } else {
            // No positional change means the drag is effectively cancelled.
            delegate?.dragControllerDidCancelDrag()
        }

        // Drop the drag state after the delegate has handled the result.
        self.context = nil
    }

    /// Cancels the active drag.
    func cancelDragging() {
        guard context != nil else { return }
        delegate?.dragControllerDidCancelDrag()
        context = nil
    }

    // MARK: - Private Methods

    /// Pushes the current gap and exclusion state to the delegate.
    private func notifyLayoutUpdate() {
        guard let context = context else { return }

        var pinnedExcludedIndex: Int?
        var pinnedGapIndex: Int?
        var normalExcludedIndex: Int?
        var normalGapIndex: Int?
        var normalGapWidth: CGFloat?

        // Hide the source tab in its original zone.
        switch context.sourceContainerType {
        case .pinned:
            pinnedExcludedIndex = context.sourceIndex
        case .normal:
            normalExcludedIndex = context.sourceIndex
        }

        // Show the insertion gap in the target zone.
        switch context.targetContainerType {
        case .pinned:
            pinnedGapIndex = context.targetIndex
        case .normal:
            normalGapIndex = context.targetIndex
            if let metrics = delegate?.dragControllerRequestMetrics() {
                normalGapWidth = calculateAverageTabWidth(from: metrics.normalTabFrames)
            }
        }

        delegate?.dragControllerDidUpdateLayout(
            pinnedExcludedIndex: pinnedExcludedIndex,
            pinnedGapIndex: pinnedGapIndex,
            normalExcludedIndex: normalExcludedIndex,
            normalGapIndex: normalGapIndex,
            normalGapWidth: normalGapWidth
        )
    }

    /// Returns the average visible tab width, ignoring placeholder frames.
    private func calculateAverageTabWidth(from frames: [CGRect]) -> CGFloat {
        let validFrames = frames.filter { $0 != .zero && $0.width > 0 }
        guard !validFrames.isEmpty else {
            return TabStripMetrics.Tab.idealWidth
        }
        let totalWidth = validFrames.reduce(0) { $0 + $1.width }
        return totalWidth / CGFloat(validFrames.count)
    }

    /// Resolves the destination zone and insertion index for the pointer.
    private func calculateTarget(
        mouseLocation: CGPoint,
        metrics: TabStripMetricsSnapshot,
        context: TabDragContext
    ) -> (zone: TabContainerType, index: Int) {
        let localPoint = delegate?.dragControllerConvertPointToLocal(mouseLocation) ?? mouseLocation

        // Hit-test the pointer against the pinned and normal containers.
        let inPinned = metrics.pinnedContainerFrame.contains(localPoint)
        let inNormal = metrics.normalContainerFrame.contains(localPoint)

        if inPinned {
            // Drag is currently over the pinned zone — cursor-based.
            let localX = localPoint.x - metrics.pinnedContainerFrame.minX
            let index = calculateGapIndex(
                localX: localX,
                tabFrames: metrics.pinnedTabFrames,
                excludedIndex: context.sourceContainerType == .pinned ? context.sourceIndex : nil
            )
            return (.pinned, index)
        } else if inNormal {
            // Drag is currently over the normal zone — edge-based with
            // hysteresis (consistent gap-flip feel regardless of where
            // the user grabbed inside the dragged tab). Falls back to
            // cursor-based when the proxy frame isn't available yet
            // (e.g. cross-zone transition's first tick before
            // targetContainerType updates to .normal).
            let excluded = context.sourceContainerType == .normal ? context.sourceIndex : nil
            if let xFrame = metrics.draggedTabFrameInNormal {
                let index = calculateGapIndexEdgeBased(
                    xFrame: xFrame,
                    tabFrames: metrics.normalTabFrames,
                    excludedIndex: excluded,
                    previousIndex: context.targetIndex
                )
                return (.normal, index)
            }
            let localX = localPoint.x - metrics.normalContainerFrame.minX + metrics.normalScrollOffset
            let index = calculateGapIndex(
                localX: localX,
                tabFrames: metrics.normalTabFrames,
                excludedIndex: excluded
            )
            return (.normal, index)
        } else {
            // Keep the previous destination while outside both zones.
            return (context.targetContainerType, context.targetIndex)
        }
    }

    /// Edge-based gap index with hysteresis for the normal zone.
    ///
    /// For each visible tab `T_j` in left-to-right order we hold a
    /// per-tab binary state: gap is BEFORE `T_j` (T_j sits to the
    /// right of the gap) or AFTER `T_j` (T_j sits to the left).
    /// `previousIndex` defines the prior demarcation: tabs at
    /// data-model index `< previousIndex` were "after-the-gap"; the
    /// rest were "before-the-gap".
    ///
    /// Per-tab hysteresis to compute the new state:
    ///   • Was "before T_j" — flip to "after T_j" iff
    ///     `xFrame.maxX >= T_j.midX` (x's right edge crosses T_j's
    ///     center going right).
    ///   • Was "after T_j" — flip to "before T_j" iff
    ///     `xFrame.minX <= T_j.midX` (x's left edge crosses T_j's
    ///     center going left).
    ///
    /// The new gap is the smallest visible-frame index whose state is
    /// "before" (or `count + 1` if none — gap goes at the end). Under
    /// monotonic motion the per-tab states stay sorted, so the first
    /// "before" we encounter is the correct demarcation. Under fast
    /// drags that straddle multiple tabs in one tick the result is
    /// still well-defined: we settle to the leftmost "before" entry,
    /// which represents the conservative side of the rapid motion.
    ///
    /// This makes the let-way trigger independent of where inside x
    /// the user originally grabbed (cursor-based hit testing depends
    /// on grab offset).
    private func calculateGapIndexEdgeBased(
        xFrame: CGRect,
        tabFrames: [CGRect],
        excludedIndex: Int?,
        previousIndex: Int
    ) -> Int {
        var visibleFrames: [(index: Int, frame: CGRect)] = []
        for (i, frame) in tabFrames.enumerated() {
            if let exclude = excludedIndex, i == exclude { continue }
            if frame == .zero { continue }
            visibleFrames.append((i, frame))
        }
        if visibleFrames.isEmpty { return 0 }

        // Map the previous data-model gap to a visibleFrames index.
        // `prevJ` is the smallest visible position whose tab was on
        // the "before-the-gap" side of the previous demarcation.
        let prevJ = visibleFrames.firstIndex(where: { $0.index >= previousIndex })
            ?? visibleFrames.count

        for (j, item) in visibleFrames.enumerated() {
            let midX = item.frame.midX
            let stateIsBefore: Bool
            if j >= prevJ {
                // Was "before T_j"; only flip to "after" if x's
                // right edge has caught up to T_j's center.
                stateIsBefore = (xFrame.maxX < midX)
            } else {
                // Was "after T_j"; only flip to "before" if x's
                // left edge has retreated past T_j's center.
                stateIsBefore = (xFrame.minX <= midX)
            }
            if stateIsBefore {
                return item.index
            }
        }
        return (visibleFrames.last?.index ?? 0) + 1
    }

    /// Calculates the gap index for a pointer position within one container.
    /// - Parameters:
    ///   - localX: Pointer x-position in container coordinates.
    ///   - tabFrames: Tab frames in container coordinates.
    ///   - excludedIndex: Source tab index excluded from layout.
    /// - Returns: Target gap index.
    private func calculateGapIndex(
        localX: CGFloat,
        tabFrames: [CGRect],
        excludedIndex: Int?
    ) -> Int {
        // Remove the dragged tab and any placeholder frames.
        var visibleFrames: [(index: Int, frame: CGRect)] = []
        for (i, frame) in tabFrames.enumerated() {
            if let exclude = excludedIndex, i == exclude {
                continue
            }
            if frame == .zero {
                continue
            }
            visibleFrames.append((i, frame))
        }

        if visibleFrames.isEmpty {
            return 0
        }

        // Insert before the first tab whose midpoint is to the right of the pointer.
        for (arrayIndex, item) in visibleFrames.enumerated() {
            let midX = item.frame.midX
            if localX < midX {
                return calculateActualInsertIndex(
                    visualIndex: arrayIndex,
                    visibleFrames: visibleFrames,
                    excludedIndex: excludedIndex
                )
            }
        }

        // Insert at the end when the pointer is past every visible tab.
        if let lastItem = visibleFrames.last {
            return lastItem.index + 1
        }

        return 0
    }

    /// Converts a visible-array index back into the underlying tab index.
    private func calculateActualInsertIndex(
        visualIndex: Int,
        visibleFrames: [(index: Int, frame: CGRect)],
        excludedIndex: Int?
    ) -> Int {
        if visualIndex < visibleFrames.count {
            return visibleFrames[visualIndex].index
        }
        return visibleFrames.last?.index ?? 0
    }
}
