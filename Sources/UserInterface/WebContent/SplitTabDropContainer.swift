// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Container view for the active WebContent area that also accepts a tab drag
/// dropped on its left or right third to start a new vertical split:
///
/// - Left third  → dragged tab becomes the **left** (primary) pane, focused
///                 tab becomes the right (secondary) pane.
/// - Right third → dragged tab becomes the **right** (secondary) pane,
///                 focused tab becomes the left (primary) pane.
///
/// The drop is only accepted when:
/// - the drag comes from the same window (cross-window drops fall through to
///   the existing new-window tear-off flow);
/// - the focused tab exists and is not the dragged tab;
/// - the focused tab is not already part of a split (per user requirement —
///   "When you drag a tab to a splitview page, remain the old logic");
/// - the cursor sits in the left third or right third of the container.
///
/// Visual hint: while a valid drag is hovering anywhere over the page area
/// (including the dead middle band), both "Add Left Split" / "Add Right
/// Split" hint cards are shown with a dashed border so the user can see
/// both potential targets at once. The middle band itself is a no-drop
/// area — drops only land in the left/right thirds.
///
/// Mouse events are not affected: `contentContainer` does not override
/// `hitTest`, so children (the Chromium native view) continue to receive
/// clicks as before.
final class SplitTabDropContainer: NSView {

    /// Fraction of the container's width that counts as a "drop here to
    /// split" zone, measured from each side edge.
    private static let edgeDropZoneFraction: CGFloat = 1.0 / 3.0

    /// Insets the visible drop hint inwards from the zone rectangle so it
    /// reads as a card rather than a hard fill that runs into the rounded
    /// page background. Fractional so the card scales with window size —
    /// fixed-pt insets shrink the relative padding on a wide window, and
    /// the Figma's cards keep a consistent ~10/9% breathing room.
    private static let dropHintHorizontalInsetFraction: CGFloat = 0.10
    private static let dropHintVerticalInsetFraction: CGFloat = 0.09
    /// Floor so the padding doesn't collapse on a narrow window.
    private static let dropHintHorizontalInsetMinimum: CGFloat = 24
    private static let dropHintVerticalInsetMinimum: CGFloat = 24
    private static let dropHintCornerRadius: CGFloat = 20
    private static let dropHintLineWidth: CGFloat = 2
    private static let dropHintLineDashPattern: [NSNumber] = [8, 6]
    /// Overall opacity of the frosted-glass card. Kept at 1.0 so the
    /// material's own translucency carries the see-through effect —
    /// `NSGlassEffectView` and `.fullScreenUI` already let page content
    /// bleed through; dropping `alphaValue` further makes the card read
    /// as thin film rather than a solid glass panel.
    private static let dropHintGlassOpacity: CGFloat = 1.0

    /// Supplies the actual web-page area (in this view's coordinate space)
    /// so the highlight and trigger zones avoid covering the URL bar and
    /// bookmark bar above it. Returns nil if no page is currently mounted,
    /// in which case the full bounds are used as a fallback.
    var pageAreaProvider: (() -> CGRect?)?

    enum DropZone {
        case left
        case right

        var labelText: String {
            switch self {
            case .left:  return NSLocalizedString("Add Left Split", comment: "Drop-zone hint shown when dragging a tab over the left third of the page")
            case .right: return NSLocalizedString("Add Right Split", comment: "Drop-zone hint shown when dragging a tab over the right third of the page")
            }
        }
    }

    weak var browserState: BrowserState?

    private let leftGlassView: NSView = SplitTabDropContainer.makeGlassView()
    private let rightGlassView: NSView = SplitTabDropContainer.makeGlassView()
    private let leftGlassHighlight = SplitTabDropContainer.makeHighlightGradient()
    private let rightGlassHighlight = SplitTabDropContainer.makeHighlightGradient()
    private let leftBorderLayer = SplitTabDropContainer.makeBorderLayer()
    private let rightBorderLayer = SplitTabDropContainer.makeBorderLayer()
    private let leftDropLabel = SplitTabDropContainer.makeDropLabel()
    private let rightDropLabel = SplitTabDropContainer.makeDropLabel()

    /// macOS 26+ exposes `NSGlassEffectView` (Apple's Liquid Glass) which
    /// already renders with its own blur, refraction, and edge highlight
    /// — exactly the look we were faking with NSVisualEffectView + white
    /// fill + gradient. On older systems we keep the
    /// ColoredVisualEffectView fallback used by the floating sidebar
    /// (`WebContentContainerViewController+FloatingSidebar.swift:91`) so
    /// the drop hint stays consistent with the rest of the app's chrome.
    private static func makeGlassView() -> NSView {
        let view: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = dropHintCornerRadius
            // `NSGlassEffectView` requires a contentView; an empty layer-
            // backed view is fine since the label and dashed border are
            // siblings of the glass (drawn directly by the container) and
            // the highlight gradient is added to `glass.layer` below.
            let content = NSView()
            content.wantsLayer = true
            glass.contentView = content
            view = glass
        } else {
            let fx = ColoredVisualEffectView()
            fx.backgroundColor = NSColor.white.withAlphaComponent(0.85)
            fx.material = .fullScreenUI
            fx.blendingMode = .withinWindow
            fx.state = .active
            view = fx
        }
        view.alphaValue = dropHintGlassOpacity
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = dropHintCornerRadius
        view.layer?.masksToBounds = true
        // The Chromium content view is added to the SplitTabDropContainer
        // *after* these subviews, so without an explicit zPosition the
        // freshly-added Chromium view's backing layer (zPosition 0, higher
        // sublayer index) renders on top of the glass card. Sit just under
        // the dashed border (zPosition 10_000) so the layer-tree compositor
        // floats both the card and the stroke above Chromium content.
        view.layer?.zPosition = 9_999
        view.isHidden = true
        return view
    }

    /// Subtle white-to-transparent gradient sublayer that fakes the
    /// top-edge "glass shine" from the Figma. NSVisualEffectView alone
    /// can't render an inner highlight, so we paint one ourselves and
    /// clip it to the card's rounded shape via the glass view's layer.
    /// Gradient unit space: (0,0) bottom-left, (1,1) top-right — so a
    /// `(0.5, 1) → (0.5, 0.5)` axis lights the top half and fades out
    /// to clear by mid-card.
    private static func makeHighlightGradient() -> CAGradientLayer {
        // NSGlassEffectView on macOS 26+ already ships with its own edge
        // shine; on the NSVisualEffectView fallback path this gradient
        // does the "top glass highlight" by itself. Keep the alpha modest
        // so both paths read consistently — the Liquid Glass effect won't
        // be doubled up by a strong overlay.
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.white.withAlphaComponent(0.25).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradient.endPoint = CGPoint(x: 0.5, y: 0.4)
        return gradient
    }

    private static func makeBorderLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineWidth = dropHintLineWidth
        layer.lineDashPattern = dropHintLineDashPattern
        layer.lineCap = .round
        layer.isHidden = true
        // Sits above the glass view (zPosition 0) and below the label
        // (zPosition 10_001) so the dashed stroke rides on top of the
        // frosted card without painting over the text.
        layer.zPosition = 10_000
        return layer
    }

    private static func makeDropLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 15, weight: .semibold)
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = true
        field.isHidden = true
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.wantsLayer = true
        return field
    }

    /// True while both drop-hint cards are visible (a valid drag is hovering
    /// the page area). Tracked separately from the per-cursor landing zone so
    /// the hints stay visible while the cursor is in the dead middle band.
    private var hintsVisible = false

    private var themeObservation: AnyObject?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Order: glass cards (bottom) → dashed border (middle, via
        // zPosition) → labels (top, via zPosition). NSView subview backing
        // layers and direct `addSublayer` calls share the same sublayer
        // list, so zPosition sorts them all together.
        addSubview(leftGlassView)
        addSubview(rightGlassView)
        leftGlassView.layer?.addSublayer(leftGlassHighlight)
        rightGlassView.layer?.addSublayer(rightGlassHighlight)
        layer?.addSublayer(leftBorderLayer)
        layer?.addSublayer(rightBorderLayer)
        addSubview(leftDropLabel)
        addSubview(rightDropLabel)
        leftDropLabel.layer?.zPosition = 10_001
        rightDropLabel.layer?.zPosition = 10_001
        leftDropLabel.stringValue = DropZone.left.labelText
        rightDropLabel.stringValue = DropZone.right.labelText
        registerForDraggedTypes([.normalTab, .pinnedTab, .phiBookmark])
        themeObservation = subscribe { [weak self] _, _ in
            self?.applyThemeColors()
        }
        applyThemeColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if hintsVisible {
            updateDropHintFrames()
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender).operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender).operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideHighlights()
    }

    // MARK: - External drag drivers (TabStrip, comfortable layout)
    //
    // The horizontal-tab TabStrip drives drags with raw mouse events instead
    // of an NSDraggingSession, so its drag doesn't flow through the
    // NSDraggingDestination methods above. These hooks let the strip query
    // the split zone for a screen point and show/hide the same highlight UI
    // while the user is dragging a tab.

    /// Returns the split zone the given screen point falls into, or `nil` if
    /// the point is outside the drop area or a split isn't allowed right now
    /// (no focused tab, or the focused tab is already part of a split).
    ///
    /// Note: dragging the focused tab onto itself is allowed — the drop
    /// will create a fresh new-tab-page as the partner pane.
    func splitZoneForScreenPoint(_ screenPoint: CGPoint, draggedTabId: Int) -> DropZone? {
        guard let pointInSelf = pointInSelfForScreenPoint(screenPoint, draggedTabId: draggedTabId) else {
            return nil
        }
        let area = pageAreaProvider?() ?? bounds
        guard area.contains(pointInSelf) else { return nil }
        let edge = area.width * Self.edgeDropZoneFraction
        if pointInSelf.x <= area.minX + edge {
            return .left
        } else if pointInSelf.x >= area.maxX - edge {
            return .right
        }
        return nil
    }

    /// True when a tab drag from the same window is hovering anywhere over
    /// the page area and would be a valid split candidate. Used by the
    /// horizontal TabStrip's manual drag flow to keep both hint cards
    /// visible while the cursor is in the dead middle band — the drop
    /// landing decision still uses `splitZoneForScreenPoint`.
    func isSplitDragContextValid(at screenPoint: CGPoint, draggedTabId: Int) -> Bool {
        guard let pointInSelf = pointInSelfForScreenPoint(screenPoint, draggedTabId: draggedTabId) else {
            return false
        }
        let area = pageAreaProvider?() ?? bounds
        return area.contains(pointInSelf)
    }

    private func pointInSelfForScreenPoint(_ screenPoint: CGPoint, draggedTabId: Int) -> CGPoint? {
        guard let state = browserState,
              let window,
              let focusedTab = state.focusingTab,
              state.splitGroup(forTabId: focusedTab.guid) == nil,
              state.splitGroup(forTabId: draggedTabId) == nil else { return nil }
        let pointInWindow = window.convertPoint(fromScreen: NSPoint(x: screenPoint.x, y: screenPoint.y))
        return convert(pointInWindow, from: nil)
    }

    /// Shows both split-drop hint cards. No-op if already shown.
    func showSplitDropHints() {
        showHighlights()
    }

    /// Hides both split-drop hint cards.
    func hideSplitDropHints() {
        hideHighlights()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = evaluate(sender)
        defer { hideHighlights() }
        guard result.operation != [], let zone = result.zone,
              let state = browserState,
              let pasteboardItem = sender.draggingPasteboard.pasteboardItems?.first,
              let source = parseDragSource(pasteboardItem),
              let focusedTabId = state.focusingTab?.guid else { return false }
        performSplitDrop(state: state,
                         source: source,
                         focusedTabId: focusedTabId,
                         zone: zone)
        return true
    }

    /// Routes a split drop based on the drag's source kind. Three paths
    /// converge here: a normal tab in the strip, a pinned tab in the
    /// favorites grid, or a (non-split) bookmark. The normal-tab and bookmark
    /// paths produce a split whose two panes are entries in the **normal
    /// opened tab list**; the pinned path keeps the dragged tab pinned and
    /// pins the focused tab next to it so the result is a pinned split.
    func performSplitDrop(state: BrowserState,
                          source: DragSource,
                          focusedTabId: Int,
                          zone: DropZone) {
        switch source {
        case .normalTab(let tabId):
            // Normalize the focused tab (the split partner) into the opened
            // tab list, otherwise the resulting split would inherit its
            // pinned-ness or bookmark binding — contrary to user intent.
            makeTabNormalOpened(state: state, tabId: focusedTabId)
            performSplitDropFromNormalTab(state: state,
                                          draggedTabId: tabId,
                                          focusedTabId: focusedTabId,
                                          zone: zone)
        case .pinnedTab(let dbGuid):
            // Pinned source preserves pinned status: the live-pinned subpath
            // pins the focused tab itself rather than unpinning the dragged
            // pane. Normalization is handled inside the helper for the
            // closed-pinned fallback only.
            performSplitDropFromPinned(state: state,
                                       pinnedDBGuid: dbGuid,
                                       focusedTabId: focusedTabId,
                                       zone: zone)
        case .bookmark(let bookmarkGuid):
            makeTabNormalOpened(state: state, tabId: focusedTabId)
            performSplitDropFromBookmark(state: state,
                                         bookmarkGuid: bookmarkGuid,
                                         focusedTabId: focusedTabId,
                                         zone: zone)
        }
    }

    private func performSplitDropFromNormalTab(state: BrowserState,
                                               draggedTabId: Int,
                                               focusedTabId: Int,
                                               zone: DropZone) {
        if draggedTabId == focusedTabId {
            // Dragged = focused → open a new tab as the partner. The new
            // tab takes the slot opposite the one the user dropped on,
            // since the "dragged" tab visually lands in the dropped slot.
            switch zone {
            case .left:
                state.openNewTabAsSplit(partnerTabId: focusedTabId, newTabSlot: .right)
            case .right:
                state.openNewTabAsSplit(partnerTabId: focusedTabId, newTabSlot: .left)
            }
            return
        }
        switch zone {
        case .left:
            state.createSplit(leftTabId: draggedTabId,
                              rightTabId: focusedTabId,
                              layout: .vertical)
        case .right:
            state.createSplit(leftTabId: focusedTabId,
                              rightTabId: draggedTabId,
                              layout: .vertical)
        }
    }

    private func performSplitDropFromPinned(state: BrowserState,
                                            pinnedDBGuid: String,
                                            focusedTabId: Int,
                                            zone: DropZone) {
        if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == pinnedDBGuid }),
           liveTab.guid != focusedTabId,
           let focusedTab = state.tabs.first(where: { $0.guid == focusedTabId }) {
            // Live pinned tab distinct from focused. Keep the dragged tab
            // pinned and pin the focused tab next to it so the resulting
            // split is itself a pinned split (the codebase's split model has
            // no mixed pinned/unpinned state — see `pinSplitInsertingAtPinnedIndex`
            // for the precedent). The previous behavior unpinned the dragged
            // tab here, which contradicted "drag from pinned" intent.
            pinFocusedTabAdjacentToPinnedAnchor(state: state,
                                                focusedTab: focusedTab,
                                                anchorPinnedGuid: liveTab.guidInLocalDB)
            let createdSplitId: String?
            switch zone {
            case .left:
                createdSplitId = state.createSplit(leftTabId: liveTab.guid,
                                                   rightTabId: focusedTabId,
                                                   layout: .vertical)
            case .right:
                createdSplitId = state.createSplit(leftTabId: focusedTabId,
                                                   rightTabId: liveTab.guid,
                                                   layout: .vertical)
            }
            if let createdSplitId {
                // `handleSplitCreated`'s pinned-inference reads the async
                // `pinnedTabs` publisher, which may not yet reflect the
                // focused tab we just pinned. Flag the split so the handler
                // forces `isPinned = true`.
                state.pendingPinnedSplitMarkByCreateId.insert(createdSplitId)
            }
            if let primaryDB = liveTab.guidInLocalDB,
               let secondaryDB = focusedTab.guidInLocalDB {
                state.persistPinnedSplitPair(primaryDB: primaryDB, secondaryDB: secondaryDB)
            }
            return
        }
        // Closed pinned tab (no live representation) or pinned tab whose
        // live representation IS the focused pane: open a fresh tab on the
        // pinned URL as the new pane. The pinned record itself is left
        // intact so the slot still exists for next time. The new partner
        // pane is a normal tab, so normalize the focused tab here (this
        // path lost the unconditional pre-switch normalization when the
        // live-pinned subpath above stopped requiring it).
        makeTabNormalOpened(state: state, tabId: focusedTabId)
        guard let pinned = state.pinnedTabs.first(where: { $0.guidInLocalDB == pinnedDBGuid }),
              let url = pinned.url, !url.isEmpty else { return }
        let newTabSlot: SplitSlot = (zone == .left) ? .left : .right
        state.openNewTabAsSplit(partnerTabId: focusedTabId,
                                newTabSlot: newTabSlot,
                                partnerNavigateURL: URLProcessor.processUserInput(url))
    }

    /// Pin `focusedTab` so it ends up adjacent to the already-pinned anchor
    /// in `pinnedTabs`. Handles the three states the focused tab can be in:
    /// normal (just pin), bookmark-bound (drop the binding then pin), or
    /// already pinned (no-op). The anchor is the dragged pinned tab's
    /// `guidInLocalDB`; passing `nil` falls back to appending at the head of
    /// the pinned list.
    private func pinFocusedTabAdjacentToPinnedAnchor(state: BrowserState,
                                                     focusedTab: Tab,
                                                     anchorPinnedGuid: String?) {
        if focusedTab.isPinned { return }
        if let dbGuid = focusedTab.guidInLocalDB, !dbGuid.isEmpty {
            // Bookmark-bound. Mirror the second branch of `makeTabNormalOpened`
            // so the bookmark cell stops claiming this tab is open before we
            // overwrite `guidInLocalDB` with a fresh pinned guid.
            focusedTab.guidInLocalDB = nil
            focusedTab.webContentWrapper?.updateTabCustomValue("")
            state.syncAllBookmarksOpenedState()
        }
        state.moveNormalTabToPinned(focusedTab,
                                    after: anchorPinnedGuid,
                                    selectAfterMove: focusedTab.isActive)
        focusedTab.isPinned = true
        state.updateNormalTabs()
    }

    private func performSplitDropFromBookmark(state: BrowserState,
                                              bookmarkGuid: String,
                                              focusedTabId: Int,
                                              zone: DropZone) {
        guard let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkGuid),
              !bookmark.isFolder,
              let url = bookmark.url, !url.isEmpty else { return }
        // If the bookmark is already open as a live tab distinct from the
        // focused pane, reuse that tab instead of opening a duplicate.
        // Mirrors the pinned path: unbind from the bookmark first so the
        // split lives in the normal opened tab list, then pair the
        // (now-unbound) tab with the focused pane.
        if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == bookmarkGuid }),
           liveTab.guid != focusedTabId,
           state.splitGroup(forTabId: liveTab.guid) == nil {
            makeTabNormalOpened(state: state, tabId: liveTab.guid)
            switch zone {
            case .left:
                state.createSplit(leftTabId: liveTab.guid,
                                  rightTabId: focusedTabId,
                                  layout: .vertical)
            case .right:
                state.createSplit(leftTabId: focusedTabId,
                                  rightTabId: liveTab.guid,
                                  layout: .vertical)
            }
            return
        }
        // Bookmark has no live representation, or its live tab IS the
        // focused pane: materialize a fresh unbound tab on the bookmark
        // URL as the new pane. The new tab lands in the dropped zone; the
        // focused pane takes the opposite slot.
        let newTabSlot: SplitSlot = (zone == .left) ? .left : .right
        state.openNewTabAsSplit(partnerTabId: focusedTabId,
                                newTabSlot: newTabSlot,
                                partnerNavigateURL: URLProcessor.processUserInput(url))
    }

    /// Ensures the given tab is a plain entry in the normal opened tab list:
    /// unpins a pinned tab and clears any bookmark binding. No-op if already
    /// in that state. Callers must not invoke this on a tab that's part of a
    /// live split — the evaluate-side guard rejects those before they reach
    /// the drop handler.
    private func makeTabNormalOpened(state: BrowserState, tabId: Int) {
        guard let tab = state.tabs.first(where: { $0.guid == tabId }) else { return }
        if tab.isPinned, let dbGuid = tab.guidInLocalDB, !dbGuid.isEmpty {
            state.movePinnedTabOut(pinnedGuid: dbGuid, to: state.normalTabs.count)
            return
        }
        if let dbGuid = tab.guidInLocalDB, !dbGuid.isEmpty {
            // Bookmark-bound (non-pinned). Drop both the Swift mirror and
            // the Chromium customGuid marker so
            // `CrossDomainNewTabNavigationThrottle` stops treating the tab
            // as bookmark-bound, then re-sync bookmark state so the
            // bookmark cell stops rendering as opened.
            tab.guidInLocalDB = nil
            tab.webContentWrapper?.updateTabCustomValue("")
            state.syncAllBookmarksOpenedState()
        }
    }

    // MARK: - Drop validation

    private struct Evaluation {
        let operation: NSDragOperation
        let zone: DropZone?
    }

    private func evaluate(_ sender: NSDraggingInfo) -> Evaluation {
        guard let state = browserState,
              let pasteboardItem = sender.draggingPasteboard.pasteboardItems?.first,
              isSameWindowDrag(pasteboardItem, sender: sender, state: state),
              let focusedTab = state.focusingTab,
              state.splitGroup(forTabId: focusedTab.guid) == nil,
              let source = parseDragSource(pasteboardItem),
              !isSourceASplit(source, state: state) else {
            hideHighlights()
            return Evaluation(operation: [], zone: nil)
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let area = pageAreaProvider?() ?? bounds
        guard area.contains(pointInSelf) else {
            hideHighlights()
            return Evaluation(operation: [], zone: nil)
        }
        // Drag is contextually valid and the cursor is over the page area:
        // show both hint cards so the user can see where they can land.
        showHighlights()
        let edge = area.width * Self.edgeDropZoneFraction
        let zone: DropZone?
        if pointInSelf.x <= area.minX + edge {
            zone = .left
        } else if pointInSelf.x >= area.maxX - edge {
            zone = .right
        } else {
            zone = nil
        }
        guard let zone else {
            // Cursor is in the dead middle band — hints stay visible but no
            // drop will land here.
            return Evaluation(operation: [], zone: nil)
        }
        return Evaluation(operation: .move, zone: zone)
    }

    /// Kinds of drags the page-workspace split drop accepts. The drag
    /// originates from one of three sidebar sections; each path produces a
    /// split whose two panes are normal opened tabs.
    enum DragSource {
        case normalTab(tabId: Int)
        case pinnedTab(dbGuid: String)
        case bookmark(guid: String)
    }

    /// Classifies the pasteboard item by drag source. Pinned drags carry
    /// both `.pinnedTab` and `.normalTab`; check `.pinnedTab` first so the
    /// pinned-aware path runs.
    private func parseDragSource(_ pasteboardItem: NSPasteboardItem) -> DragSource? {
        if let dbGuid = pasteboardItem.string(forType: .pinnedTab), !dbGuid.isEmpty {
            return .pinnedTab(dbGuid: dbGuid)
        }
        if let bookmarkGuid = pasteboardItem.string(forType: .phiBookmark), !bookmarkGuid.isEmpty {
            return .bookmark(guid: bookmarkGuid)
        }
        if let tabIdString = pasteboardItem.string(forType: .normalTab),
           let tabId = Int(tabIdString) {
            return .normalTab(tabId: tabId)
        }
        return nil
    }

    /// True when the drag source itself represents a split — those drops are
    /// rejected outright so the page workspace doesn't try to nest a split
    /// inside a split. Detects live splits via `splitGroup`, persisted pinned
    /// splits via `Tab.splitPartnerGuid` (covers the closed-pinned-split case
    /// where the pinned leftTab carries `guid == -1` and the live lookup
    /// misses), and split-view bookmarks via `secondaryUrl`. Folder bookmarks
    /// are also rejected — they can't be a split pane.
    private func isSourceASplit(_ source: DragSource, state: BrowserState) -> Bool {
        switch source {
        case .normalTab(let tabId):
            return state.splitGroup(forTabId: tabId) != nil
        case .pinnedTab(let dbGuid):
            if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               state.splitGroup(forTabId: liveTab.guid) != nil {
                return true
            }
            if let pinned = state.pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid }),
               let partner = pinned.splitPartnerGuid, !partner.isEmpty {
                return true
            }
            return false
        case .bookmark(let bookmarkGuid):
            guard let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkGuid) else {
                return true
            }
            if bookmark.isFolder { return true }
            if let secondary = bookmark.secondaryUrl, !secondary.isEmpty { return true }
            return false
        }
    }

    private func isSameWindowDrag(_ pasteboardItem: NSPasteboardItem,
                                  sender: NSDraggingInfo,
                                  state: BrowserState) -> Bool {
        guard let sourceIdString = pasteboardItem.string(forType: .sourceWindowId),
              let sourceId = Int(sourceIdString),
              sourceId == state.windowId else { return false }
        // Belt-and-braces: a pasteboard-only check trusts the source view to
        // have stamped the right windowId. Cross-check that `draggingSource`
        // is owned by this window so a forged pasteboard from a sibling
        // window can't masquerade as same-window. Non-NSView sources
        // (external drags) wouldn't have set `sourceWindowId` anyway and are
        // already rejected by the check above.
        if let sourceView = sender.draggingSource as? NSView,
           sourceView.window !== self.window {
            return false
        }
        return true
    }

    // MARK: - Visual feedback

    private func applyThemeColors() {
        // Glass tint is owned by `NSVisualEffectView`'s material. Only the
        // dashed stroke and label text are painted by us. `tertiaryLabelColor`
        // adapts to light/dark and stays visible over arbitrary page content
        // — the theme's `border` color is tuned for chrome separators and
        // fades to invisible against a busy web page.
        let stroke = NSColor.tertiaryLabelColor
        let text = ThemedColor.textPrimary.resolve(in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftBorderLayer.strokeColor = stroke.cgColor
        rightBorderLayer.strokeColor = stroke.cgColor
        CATransaction.commit()
        leftDropLabel.textColor = text
        rightDropLabel.textColor = text
    }

    private func showHighlights() {
        if !hintsVisible {
            hintsVisible = true
            updateDropHintFrames()
        }
        // Suppress implicit fade so the cards snap on rather than fade in.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftBorderLayer.isHidden = false
        rightBorderLayer.isHidden = false
        CATransaction.commit()
        leftGlassView.isHidden = false
        rightGlassView.isHidden = false
        leftDropLabel.isHidden = false
        rightDropLabel.isHidden = false
    }

    private func hideHighlights() {
        hintsVisible = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftBorderLayer.isHidden = true
        rightBorderLayer.isHidden = true
        CATransaction.commit()
        leftGlassView.isHidden = true
        rightGlassView.isHidden = true
        leftDropLabel.isHidden = true
        rightDropLabel.isHidden = true
    }

    private func updateDropHintFrames() {
        let area = pageAreaProvider?() ?? bounds
        let zoneWidth = area.width * Self.edgeDropZoneFraction
        updateDropHintFrame(
            glass: leftGlassView,
            highlight: leftGlassHighlight,
            border: leftBorderLayer,
            label: leftDropLabel,
            zoneOriginX: area.minX,
            zoneWidth: zoneWidth,
            area: area
        )
        updateDropHintFrame(
            glass: rightGlassView,
            highlight: rightGlassHighlight,
            border: rightBorderLayer,
            label: rightDropLabel,
            zoneOriginX: area.maxX - zoneWidth,
            zoneWidth: zoneWidth,
            area: area
        )
    }

    private func updateDropHintFrame(glass: NSView,
                                     highlight: CAGradientLayer,
                                     border: CAShapeLayer,
                                     label: NSTextField,
                                     zoneOriginX: CGFloat,
                                     zoneWidth: CGFloat,
                                     area: NSRect) {
        let horizontalInset = max(Self.dropHintHorizontalInsetMinimum,
                                  zoneWidth * Self.dropHintHorizontalInsetFraction)
        let verticalInset = max(Self.dropHintVerticalInsetMinimum,
                                area.height * Self.dropHintVerticalInsetFraction)
        let hintRect = NSRect(
            x: zoneOriginX + horizontalInset,
            y: area.minY + verticalInset,
            width: max(0, zoneWidth - horizontalInset * 2),
            height: max(0, area.height - verticalInset * 2)
        )
        glass.frame = hintRect
        let path = CGPath(
            roundedRect: hintRect,
            cornerWidth: Self.dropHintCornerRadius,
            cornerHeight: Self.dropHintCornerRadius,
            transform: nil
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Highlight is a sublayer of the glass view's layer, so its frame
        // lives in the glass view's local coordinate space (origin (0,0),
        // size = hintRect.size). Disable implicit animations so it snaps
        // with the glass frame rather than tweening.
        highlight.frame = CGRect(origin: .zero, size: hintRect.size)
        border.path = path
        CATransaction.commit()

        let labelSize = label.intrinsicContentSize
        label.frame = NSRect(
            x: hintRect.midX - labelSize.width / 2,
            y: hintRect.midY - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
    }
}
