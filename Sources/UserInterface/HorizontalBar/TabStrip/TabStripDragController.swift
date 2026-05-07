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

        // Resolve the destination zone and gap index.
        let (targetZone, targetIndex) = calculateTarget(
            mouseLocation: mouseLocation,
            metrics: metrics,
            context: context
        )

        // Resolve the chip (if any) whose run starts at the gap
        // target. Both the gap-side decision and the leading-edge
        // join detection key off this.
        let leadingChip: TabStripChipFrame? = (targetZone == .normal)
            ? metrics.chipFrames.first(where: { $0.firstMemberIndex == targetIndex })
            : nil

        // Compute cursor x in normalContainer's layout space (= same
        // space chipFrame is in). Used by both the chip step-aside
        // visual decision and the leading-edge auto-join gating.
        let cursorInContainer: CGFloat = {
            guard targetZone == .normal else { return 0 }
            let localPoint = delegate?.dragControllerConvertPointToLocal(mouseLocation) ?? mouseLocation
            return localPoint.x
                - metrics.normalContainerFrame.minX
                + metrics.normalScrollOffset
        }()

        // Cursor on chip's left half (or further left) → gap before
        // chip (chip slides right to make room). Right half → gap
        // after chip (chip stays put, only first member slides).
        let gapBeforeChip: Bool = {
            guard let chip = leadingChip else { return false }
            return cursorInContainer < chip.frame.midX
        }()

        // Auto-join leading edge fires when the cursor sits on the
        // chip's right half (≥ chip.midX) or further right. Mirrors
        // `gapBeforeChip` so visual and commit agree: gap-after-chip
        // visualization (cursor on right half) ⇒ join; gap-before-chip
        // visualization (cursor on left half / leading whitespace)
        // ⇒ park before the group, no join.
        let leadingJoinToken: String? = {
            guard let chip = leadingChip,
                  chip.token != context.draggingTab.groupToken,
                  cursorInContainer >= chip.frame.midX else { return nil }
            return chip.token
        }()

        // Symmetric leading-edge LEAVE: when the dragged tab is in
        // some group AND the cursor sits on that group's chip's left
        // half (or further left), the user is dragging out via the
        // leading edge. Required for groups at the strip's leading
        // edge (lowerBound = 0) where the geometric check
        // (`toIndex < lowerBound`) can never trigger. Threshold
        // mirrors `gapBeforeChip` (cursor < chip.midX), so visual
        // gap-before-chip and "leave the group" agree. Not
        // constrained to `targetIndex == firstMemberIndex` so
        // dragging the FIRST member out (where after exclusion
        // `targetIndex` points to the next visible member) is also
        // handled.
        let leadingLeaveToken: String? = {
            guard let token = context.draggingTab.groupToken,
                  let chip = metrics.chipFrames.first(where: { $0.token == token }),
                  cursorInContainer < chip.frame.midX else { return nil }
            return token
        }()

        // Update the drag target state.
        let changed = context.targetContainerType != targetZone
            || context.targetIndex != targetIndex
            || context.gapBeforeRunStartChip != gapBeforeChip
            || context.targetGroupForLeadingJoin != leadingJoinToken
            || context.targetGroupForLeadingLeave != leadingLeaveToken
        context.targetContainerType = targetZone
        context.targetIndex = targetIndex
        context.gapBeforeRunStartChip = gapBeforeChip
        context.targetGroupForLeadingJoin = leadingJoinToken
        context.targetGroupForLeadingLeave = leadingLeaveToken

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
            // Drag is currently over the pinned zone.
            let localX = localPoint.x - metrics.pinnedContainerFrame.minX
            let index = calculateGapIndex(
                localX: localX,
                tabFrames: metrics.pinnedTabFrames,
                excludedIndex: context.sourceContainerType == .pinned ? context.sourceIndex : nil
            )
            return (.pinned, index)
        } else if inNormal {
            // Drag is currently over the normal zone.
            let localX = localPoint.x - metrics.normalContainerFrame.minX + metrics.normalScrollOffset
            let index = calculateGapIndex(
                localX: localX,
                tabFrames: metrics.normalTabFrames,
                excludedIndex: context.sourceContainerType == .normal ? context.sourceIndex : nil
            )
            return (.normal, index)
        } else {
            // Keep the previous destination while outside both zones.
            return (context.targetContainerType, context.targetIndex)
        }
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
