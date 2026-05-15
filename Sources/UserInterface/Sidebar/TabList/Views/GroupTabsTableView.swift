// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// `NSTableView` subclass embedded inside `TabGroupCellView` to render the
/// member tabs of a Chromium tab group. Lives WITHOUT an enclosing
/// `NSScrollView` so the outer outline view stays the sole scroller.
/// Handles mouse gestures itself so grouped-tab drags can be started
/// from the outer outline view instead of AppKit's embedded-table drag
/// pipeline.
final class GroupTabsTableView: NSTableView {
    weak var phiTableDelegate: GroupTabsTableViewDelegate?
    private var pendingDragRow: Int?
    private var pendingMouseDownEvent: NSEvent?
    private var manualDragInProgress = false

    /// Pin the inner cell to the row's full rect so it always tracks
    /// `bounds.width`, regardless of `NSTableColumn.width`. The default
    /// implementation derives the cell rect from `column.width`, which
    /// can lag behind the table's actual bounds (autoresizing mask is
    /// proportional, and existing rows are not re-framed when we mutate
    /// `column.width` manually). This mirrors the pattern used in
    /// `SideBarOutlineView.frameOfCell` for tab-group rows.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let rowRect = rect(ofRow: row)
        return NSRect(x: 0,
                      y: rowRect.minY,
                      width: rowRect.width - 4,
                      height: rowRect.height)
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        pendingDragRow = row
        pendingMouseDownEvent = event
        manualDragInProgress = false
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] inner.mouseDown row=\(row) " +
            "windowPoint=\(event.locationInWindow)"
        )
    }

    override func mouseDragged(with event: NSEvent) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] inner.mouseDragged pendingRow=\(pendingDragRow ?? -1) " +
            "manual=\(manualDragInProgress)"
        )
        guard !manualDragInProgress,
              let row = pendingDragRow,
              row >= 0,
              let mouseDownEvent = pendingMouseDownEvent else {
            return
        }

        manualDragInProgress = true
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] inner.beginManualDrag row=\(row)")
        phiTableDelegate?.tableView(self,
                                    beginDraggingRow: row,
                                    with: mouseDownEvent)
    }

    override func mouseUp(with event: NSEvent) {
        if !manualDragInProgress,
           let clickedRow = pendingDragRow,
           clickedRow >= 0,
           clickedRow == row(at: convert(event.locationInWindow, from: nil)) {
            phiTableDelegate?.tableView(self, didClickRow: clickedRow)
        }
        pendingDragRow = nil
        pendingMouseDownEvent = nil
        manualDragInProgress = false
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] inner.mouseUp")
    }
}

protocol GroupTabsTableViewDelegate: AnyObject {
    func tableView(_ tableView: GroupTabsTableView,
                   beginDraggingRow row: Int,
                   with event: NSEvent)
    func tableView(_ tableView: GroupTabsTableView,
                   didClickRow row: Int)
}
