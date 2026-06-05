// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Delegate protocol for handling middle mouse button click events on outline view items
protocol SideBarOutlineViewDelegate: AnyObject {
    /// Called when a row is clicked with the middle mouse button
    /// - Parameters:
    ///   - outlineView: The outline view that received the click
    ///   - row: The row index that was clicked, or -1 if click was outside any row
    ///   - location: Click location in outline-view coordinates — lets the
    ///     delegate route middle-click within a merged splitPair row to the
    ///     specific pane (left/right) the user actually hit.
    func outlineView(_ outlineView: SideBarOutlineView,
                     didMiddleClickRow row: Int,
                     at location: NSPoint)
    func outlineView(_ outlineView: SideBarOutlineView, didClickRow row: Int)
    func outlineView(_ outlineView: SideBarOutlineView,
                     beginDraggingTabAtRow row: Int,
                     with mouseDownEvent: NSEvent)
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, movedTo screenPoint: NSPoint)
    func outlineView(_ outlineView: NSOutlineView, draggingEntered sender: any NSDraggingInfo)
}

class SideBarOutlineView: NSOutlineView {
    static let indentation = 10
    private static let dragThreshold: CGFloat = 5

    var bottomPadding: CGFloat = 0 {
        didSet {
            updateDocumentHeightIfNeeded()
        }
    }

    private(set) var rightClickedRow: Int?
    /// Click location in outline-view coordinates, set together with
    /// `rightClickedRow` when the context menu is requested.
    private(set) var rightClickedLocation: NSPoint?
    private var isUpdatingDocumentHeight = false
    
    /// Delegate for handling middle mouse button click events
    weak var phiOutlineDelegate: SideBarOutlineViewDelegate?

    private var pendingTabDragRow: Int?
    private var pendingTabDragStartPoint: NSPoint?
    private var pendingTabMouseDownEvent: NSEvent?
    private var tabDragThresholdPassed = false
    private var tabDragBelowThresholdLogged = false

    override func setFrameSize(_ newSize: NSSize) {
        var adjusted = newSize
        if !isUpdatingDocumentHeight {
            let minH = Self.documentHeight(
                contentHeight: contentHeightForRows(),
                visibleHeight: enclosingScrollView?.contentSize.height ?? 0,
                bottomPadding: bottomPadding
            )
            adjusted.height = max(adjusted.height, minH)
        }

        let oldSize = frame.size
        super.setFrameSize(adjusted)

        if !isUpdatingDocumentHeight,
           abs(oldSize.width - adjusted.width) > 0.5 || abs(oldSize.height - adjusted.height) > 0.5 {
            updateDocumentHeightIfNeeded()
        }
    }

    override func reloadData() {
        super.reloadData()
        updateDocumentHeightIfNeeded()
    }

    override func noteNumberOfRowsChanged() {
        super.noteNumberOfRowsChanged()
        updateDocumentHeightIfNeeded()
    }
    
    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        rightClickedLocation = location
        rightClickedRow = row(at: location)
        return self.menu
    }
    
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else {
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] mouseDown ignored type=\(event.type.rawValue)"
            )
            resetTabDragThresholdState()
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        let itemTypeDescription: String = {
            guard index >= 0,
                  let item = item(atRow: index) as? SidebarItem else {
                return "none"
            }
            return String(describing: item.itemType)
        }()
        AppLogDebug(
            "[SIDEBAR_TAB_DRAG_THRESHOLD] mouseDown row=\(index) " +
            "itemType=\(itemTypeDescription) point=\(point)"
        )
        if index >= 0,
           let item = item(atRow: index) as? SidebarItem,
           item.itemType == .tab {
            pendingTabDragRow = index
            pendingTabDragStartPoint = point
            pendingTabMouseDownEvent = event
            tabDragThresholdPassed = false
            tabDragBelowThresholdLogged = false
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] pending normal tab row=\(index)"
            )
            return
        } else {
            resetTabDragThresholdState()
        }
        if index >= 0 {
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] forwarding mouseDown to super row=\(index)"
            )
            super.mouseDown(with: event)
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] super mouseDown returned row=\(index)"
            )
        } else if let window {
            AppLogDebug("[SIDEBAR_TAB_DRAG_THRESHOLD] dragging window from empty area")
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let row = pendingTabDragRow,
              let startPoint = pendingTabDragStartPoint,
              let mouseDownEvent = pendingTabMouseDownEvent,
              row >= 0,
              row < numberOfRows,
              let item = item(atRow: row) as? SidebarItem,
              item.itemType == .tab else {
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] mouseDragged passthrough " +
                "pendingRow=\(pendingTabDragRow.map(String.init) ?? "nil")"
            )
            super.mouseDragged(with: event)
            return
        }

        if !tabDragThresholdPassed {
            let currentPoint = convert(event.locationInWindow, from: nil)
            let dx = abs(currentPoint.x - startPoint.x)
            let dy = abs(currentPoint.y - startPoint.y)

            guard dx > Self.dragThreshold || dy > Self.dragThreshold else {
                if !tabDragBelowThresholdLogged {
                    tabDragBelowThresholdLogged = true
                    AppLogDebug(
                        "[SIDEBAR_TAB_DRAG_THRESHOLD] below threshold row=\(row) " +
                        "dx=\(dx) dy=\(dy)"
                    )
                }
                return
            }

            tabDragThresholdPassed = true
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] threshold passed row=\(row) " +
                "dx=\(dx) dy=\(dy)"
            )
            phiOutlineDelegate?.outlineView(
                self,
                beginDraggingTabAtRow: row,
                with: mouseDownEvent)
        }
    }

    override func mouseUp(with event: NSEvent) {
        AppLogDebug(
            "[SIDEBAR_TAB_DRAG_THRESHOLD] mouseUp reset " +
            "pendingRow=\(pendingTabDragRow.map(String.init) ?? "nil") " +
            "passed=\(tabDragThresholdPassed)"
        )
        defer {
            resetTabDragThresholdState()
        }
        if let pendingRow = pendingTabDragRow {
            if !tabDragThresholdPassed {
                let point = convert(event.locationInWindow, from: nil)
                if pendingRow == row(at: point) {
                    AppLogDebug("[SIDEBAR_TAB_DRAG_THRESHOLD] click normal tab row=\(pendingRow)")
                    phiOutlineDelegate?.outlineView(self, didClickRow: pendingRow)
                }
            }
            return
        }
        super.mouseUp(with: event)
    }
    
    override func otherMouseDown(with event: NSEvent) {
        // Check if it's a middle mouse button click (button number 2)
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        
        let clickLocation = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: clickLocation)

        // Notify delegate about the middle click
        phiOutlineDelegate?.outlineView(self,
                                        didMiddleClickRow: clickedRow,
                                        at: clickLocation)
    }
    
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        // Tab-group rows render as self-contained `TabGroupCellView`
        // leaves; let them span the full row width starting at x=0.
        if let item = item(atRow: row) as? SidebarItem,
           item.itemType == .tabGroup {
            let rowRect = rect(ofRow: row)
            return NSRect(x: 0,
                          y: rowRect.minY,
                          width: rowRect.width,
                          height: rowRect.height)
        }
        let origin = super.frameOfCell(atColumn: column, row: row)
        guard let item = item(atRow: row) as? SidebarItem, item.isBookmark else {
            return origin
        }
        var rect = origin
        rect.size.width = self.frame.width
        let baseLevel = max(0, level(forRow: row))
        let effectiveLevel: Int
        if let override = (item as? SidebarIndentationLevelProviding)?.indentationLevelOverride {
            effectiveLevel = max(baseLevel, override)
        } else {
            effectiveLevel = baseLevel
        }
        let indent = CGFloat(effectiveLevel * Self.indentation)
        rect.origin.x = indent
        rect.size.width -= indent /*+ NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)*/
        return rect
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // hide disclosure triangle
        return .zero
    }
    
    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        phiOutlineDelegate?.outlineView(self, draggingSession: session, movedTo: screenPoint)
    }
    
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        phiOutlineDelegate?.outlineView(self, draggingEntered: sender)
        return super.draggingEntered(sender)
    }

    static func documentHeight(contentHeight: CGFloat, visibleHeight: CGFloat, bottomPadding: CGFloat) -> CGFloat {
        max(visibleHeight, contentHeight + max(0, bottomPadding))
    }

    private func updateDocumentHeightIfNeeded() {
        guard !isUpdatingDocumentHeight else { return }

        let targetHeight = Self.documentHeight(
            contentHeight: contentHeightForRows(),
            visibleHeight: enclosingScrollView?.contentSize.height ?? 0,
            bottomPadding: bottomPadding
        )

        guard abs(frame.height - targetHeight) > 0.5 else { return }

        isUpdatingDocumentHeight = true
        setFrameSize(NSSize(width: frame.width, height: targetHeight))
        isUpdatingDocumentHeight = false
    }

    private func contentHeightForRows() -> CGFloat {
        guard numberOfRows > 0 else { return 0 }
        return rect(ofRow: numberOfRows - 1).maxY
    }

    private func resetTabDragThresholdState() {
        pendingTabDragRow = nil
        pendingTabDragStartPoint = nil
        pendingTabMouseDownEvent = nil
        tabDragThresholdPassed = false
        tabDragBelowThresholdLogged = false
    }
}
