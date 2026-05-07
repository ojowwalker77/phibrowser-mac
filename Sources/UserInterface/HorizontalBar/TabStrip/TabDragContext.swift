// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

enum TabContainerType {
    case pinned
    case normal
}

/// Stores the source and current target state for an active tab drag.
final class TabDragContext {
    // MARK: - Source State

    /// Dragged tab.
    let draggingTab: Tab
    /// Original container type.
    let sourceContainerType: TabContainerType
    /// Original index.
    let sourceIndex: Int
    /// Mouse location at drag start in tab-strip coordinates.
    let initialMouseLocation: CGPoint
    /// Source tab frame in container coordinates.
    let initialTabFrame: CGRect
    /// Width of the dragged tab, used when sizing the gap.
    let draggedTabWidth: CGFloat

    // MARK: - Target State

    /// Current destination container type.
    var targetContainerType: TabContainerType
    /// Current destination index.
    var targetIndex: Int
    /// When `targetIndex` falls at a tab-group's leading edge (= the
    /// group's first member's index in `normalTabs`), this flag
    /// records whether the cursor sits on the chip's left half. The
    /// layout engine uses it to decide whether the drag-gap opens
    /// *before* the chip (chip slides right to make room) or *after*
    /// the chip (chip stays, first member slides right).
    var gapBeforeRunStartChip: Bool = false

    /// Token of the group whose leading edge the drop would attach
    /// the dragged tab to (= chip whose `firstMemberIndex` equals
    /// `targetIndex`, when the dragged tab isn't already in that
    /// group). Non-nil means a leading-edge auto-join is pending; nil
    /// means the drop wouldn't change the dragged tab's group
    /// membership at this position. Used by `hasPositionChanged` so
    /// drops that don't move the tab physically but DO change its
    /// group membership (e.g. dragging the tab immediately to the
    /// left of a chip onto the chip's region) still take the commit
    /// path instead of being silently cancelled.
    var targetGroupForLeadingJoin: String?
    /// Current mouse location in tab-strip coordinates.
    var currentMouseLocation: CGPoint

    // MARK: - Derived State

    /// Whether the drag crosses between pinned and normal zones.
    var isCrossZoneDrag: Bool {
        sourceContainerType != targetContainerType
    }

    var currentTabFrame: CGRect {
        var frame = initialTabFrame
        let deltaX = currentMouseLocation.x - initialMouseLocation.x
        frame.origin.x += deltaX
        return frame
    }

    /// Whether the drag would result in a real move OR a group
    /// membership change. Drops at the same physical slot as the
    /// source (`targetIndex == sourceIndex` or `sourceIndex + 1`)
    /// would normally be no-ops, but a leading-edge drop next to a
    /// chip can flip the dragged tab's group membership via the
    /// auto-join path — those need the commit path even though the
    /// position is unchanged.
    var hasPositionChanged: Bool {
        if isCrossZoneDrag {
            return true
        }
        if targetIndex != sourceIndex && targetIndex != sourceIndex + 1 {
            return true
        }
        return targetGroupForLeadingJoin != nil
    }

    // MARK: - Init

    init(
        draggingTab: Tab,
        sourceContainerType: TabContainerType,
        sourceIndex: Int,
        initialMouseLocation: CGPoint,
        initialTabFrame: CGRect
    ) {
        self.draggingTab = draggingTab
        self.sourceContainerType = sourceContainerType
        self.sourceIndex = sourceIndex
        self.initialMouseLocation = initialMouseLocation
        self.initialTabFrame = initialTabFrame
        self.draggedTabWidth = initialTabFrame.width

        // Start with the source position as the initial target.
        self.targetContainerType = sourceContainerType
        self.targetIndex = sourceIndex
        self.currentMouseLocation = initialMouseLocation
    }
}
