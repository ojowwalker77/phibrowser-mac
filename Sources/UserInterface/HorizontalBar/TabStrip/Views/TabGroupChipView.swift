// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Chip rendered to the left of each visible group's first member tab
/// on the horizontal strip.
///
/// Visual structure:
///   ┌─────────────────────────────────┐
///   │ ● Work · 3 tabs            [3]  │
///   └─────────────────────────────────┘
///
/// Width is pre-measured by `chipWidth(...)` and fed to the layout
/// engine via `TabStripLayoutInput.chipFullWidths` so chip width and
/// tab-width allocation are derived from the same pass.
final class TabGroupChipView: NSView {
    // MARK: - Metrics

    static let height: CGFloat = 32
    static let cornerRadius: CGFloat = 5
    static let leadingPadding: CGFloat = 6
    static let dotSize: CGFloat = 16
    static let dotToLabelGap: CGFloat = 6
    static let labelRightPadding: CGFloat = 6
    static let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let countFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    static let countHorizontalPadding: CGFloat = 6
    static let countVerticalPadding: CGFloat = 1
    static let countToLabelGap: CGFloat = 6
    static let maxFullWidth: CGFloat = 180
    /// Extra slack added to the measured label width when computing
    /// the chip's overall width. NSTextField (TextKit) renders text
    /// a hair wider than `NSString.size(withAttributes:)` reports —
    /// glyph side-bearing, subpixel rounding, plus `.byTruncatingTail`
    /// being conservative about reserving space for the ellipsis.
    /// Without this slack the label gets exactly its natural width
    /// and gets aggressively truncated to "h…" even for short
    /// titles like "hello".
    static let labelSafetyMargin: CGFloat = 4

    // MARK: - Callbacks (set by TabStrip)

    /// Called when the chip is clicked (mouseUp inside bounds, no drag,
    /// not a right-click). `TabStrip` uses this to fire
    /// `bridge.updateTabGroupCollapsed(...)`.
    var onClick: ((String) -> Void)?

    /// Called to populate the right-click menu. `TabStrip` reuses
    /// `TabGroupSidebarItem.makeContextMenu` here. Returns nil → no menu.
    var onMenuRequest: ((String) -> NSMenu?)?

    /// Fired when chip mouseDown + horizontal drag exceeds threshold —
    /// promotes click-pending to active group drag. Window coordinates
    /// of the current mouse position.
    var onDragStart: ((_ token: String, _ windowLocation: CGPoint) -> Void)?

    /// Fired on every `mouseDragged` while drag is active.
    var onDrag: ((_ token: String, _ windowLocation: CGPoint) -> Void)?

    /// Fired on `mouseUp` when the drag was active (not on a click).
    var onDragEnd: ((_ token: String, _ windowLocation: CGPoint) -> Void)?

    /// Fired when the chip's hover state flips. `TabStrip` uses this to
    /// hide / restore the separators on either side of the chip, mirroring
    /// the hovered-tab rule in `updateSeparators`.
    var onHoverChanged: ((_ token: String, _ isHovered: Bool) -> Void)?

    // MARK: - Hover state

    private var isHovered: Bool = false {
        didSet {
            guard oldValue != isHovered else { return }
            applyAppearance()
            onHoverChanged?(token, isHovered)
        }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var mouseDownInside: Bool = false

    // MARK: - Click vs drag state machine
    //
    // mouseDown captures `mouseDownLocation` and sets pendingAction = .click.
    // mouseDragged promotes to `.drag` once |Δx| crosses the threshold and
    // fires `onDragStart` once. Subsequent drag events fire `onDrag`.
    // mouseUp routes to `onClick` (still .click) or `onDragEnd` (.drag).

    private enum PendingChipAction {
        case idle
        case click
        case drag
    }
    private var pendingAction: PendingChipAction = .idle
    private var mouseDownLocation: CGPoint = .zero

    /// Horizontal pixel threshold to promote click → drag. Matches
    /// `TabGroupDragController.dragActivationThreshold`.
    private static let dragActivationThreshold: CGFloat = 4

    // MARK: - Data

    private(set) var token: String = ""
    private(set) var color: GroupColor = .grey
    private(set) var displayTitle: String = ""
    private(set) var memberCount: Int = 0
    private(set) var hasUserSetTitle: Bool = false
    private(set) var isCollapsed: Bool = false
    private(set) var memberFavicons: [Data?] = []

    // MARK: - Subviews / sublayers

    private let colorDotLayer = CALayer()
    private let labelField: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.isEditable = false
        tf.isSelectable = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.font = TabGroupChipView.labelFont
        // Match the regular tab title color. `UnifiedTabTitleView` uses
        // SwiftUI's default `.primary` (system-adaptive label color);
        // `.labelColor` is the AppKit equivalent.
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.cell?.usesSingleLineMode = true
        return tf
    }()
    private let countField: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.isEditable = false
        tf.isSelectable = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.font = TabGroupChipView.countFont
        tf.textColor = .secondaryLabelColor
        tf.alignment = .center
        return tf
    }()
    private let countBackgroundLayer = CALayer()
    private let mosaicView = TabGroupChipMosaicView()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.cornerRadius
        // Suppress implicit animation on the chip's own backgroundColor
        // (toggled by hover in `applyAppearance`).
        layer?.actions = ["backgroundColor": NSNull()]

        layer?.addSublayer(colorDotLayer)
        layer?.addSublayer(countBackgroundLayer)

        colorDotLayer.cornerRadius = Self.dotSize / 2.0
        colorDotLayer.masksToBounds = true

        // Suppress implicit animations for layers we manage explicitly.
        colorDotLayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        countBackgroundLayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                        "cornerRadius": NSNull()]

        addSubview(labelField)
        addSubview(countField)
        addSubview(mosaicView)
        mosaicView.isHidden = true

        toolTip = NSLocalizedString(
            "Click to collapse or expand group",
            comment: "Tab Groups - cursor tooltip for horizontal-strip group chip")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    /// Pushes a new render state. Called by `TabStrip` once per layout
    /// pass; cheap (no measurement, just property assignments).
    func configure(
        token: String,
        color: GroupColor,
        displayTitle: String,
        memberCount: Int,
        hasUserSetTitle: Bool,
        isCollapsed: Bool,
        memberFavicons: [Data?]
    ) {
        self.token = token
        self.color = color
        self.displayTitle = displayTitle
        self.memberCount = memberCount
        self.hasUserSetTitle = hasUserSetTitle
        self.isCollapsed = isCollapsed
        self.memberFavicons = memberFavicons

        labelField.stringValue = displayTitle
        countField.stringValue = "\(memberCount)"
        mosaicView.configure(memberFavicons: memberFavicons, memberCount: memberCount)

        applyAppearance()
        needsLayout = true
    }

    /// Lightweight update used by `TabStrip` when a member's
    /// favicon data changes while the group is collapsed. Avoids
    /// the full configure (which would force a chip-width refresh
    /// and a strip relayout) — only the mosaic's cell contents
    /// change.
    ///
    /// Precondition: caller must have already invoked `configure(...)`
    /// with `isCollapsed: true` at least once, so `mosaicView.frame`
    /// is set by a prior `layout()` pass. Calling this before the
    /// first collapsed layout would leave the mosaic at `.zero` until
    /// the next layout pass.
    func updateMosaic(memberFavicons: [Data?]) {
        self.memberFavicons = memberFavicons
        mosaicView.configure(memberFavicons: memberFavicons, memberCount: memberCount)
    }

    // MARK: - Appearance

    private func applyAppearance() {
        // Hover background — same `ThemedColor.hover` used by tabs and
        // bookmarks, so the click-to-collapse affordance reads with the
        // same visual language as adjacent tabs.
        layer?.backgroundColor = isHovered
            ? ThemedColor.hover.resolve(in: self).cgColor
            : NSColor.clear.cgColor

        colorDotLayer.backgroundColor = color.nsColor.cgColor
        countBackgroundLayer.backgroundColor = color.chipHoverTintColor.cgColor
        countBackgroundLayer.cornerRadius = (TabGroupChipView.countFont.pointSize +
                                              Self.countVerticalPadding * 2) / 2.0

        // Count badge: only when expanded + user-named. When the mosaic
        // shows (collapsed), the count is suppressed because the mosaic
        // carries the count via the overflow cell.
        let showCount = hasUserSetTitle && !isCollapsed
        countField.isHidden = !showCount
        countBackgroundLayer.isHidden = !showCount
        mosaicView.isHidden = !isCollapsed
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Re-resolve programmatic colors against the new appearance.
        applyAppearance()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Color dot sits at the leading edge, vertically centered.
        let dotY = (bounds.height - Self.dotSize) / 2
        colorDotLayer.frame = CGRect(x: Self.leadingPadding, y: dotY,
                                      width: Self.dotSize, height: Self.dotSize)

        let labelX = Self.leadingPadding + Self.dotSize + Self.dotToLabelGap
        let labelHeight = ceil(Self.labelFont.ascender - Self.labelFont.descender + Self.labelFont.leading)
        let trailingX = bounds.width - Self.labelRightPadding

        if isCollapsed {
            // Mosaic anchored to the trailing edge.
            let mosaicW = TabGroupChipMosaicView.mosaicSize
            let mosaicX = trailingX - mosaicW
            let mosaicY = (bounds.height - mosaicW) / 2
            mosaicView.frame = CGRect(x: mosaicX, y: mosaicY,
                                       width: mosaicW, height: mosaicW)

            let labelMaxX = mosaicX - Self.countToLabelGap
            labelField.frame = CGRect(x: labelX, y: (bounds.height - labelHeight) / 2,
                                       width: max(0, labelMaxX - labelX), height: labelHeight)
        } else if hasUserSetTitle {
            // Count badge anchored to the trailing edge.
            let countString = countField.stringValue as NSString
            let countTextWidth = countString.size(withAttributes: [.font: Self.countFont]).width
            let countWidth = ceil(countTextWidth) + Self.countHorizontalPadding * 2
            let countHeight = Self.countFont.pointSize + Self.countVerticalPadding * 2
            let countX = trailingX - countWidth
            let countY = (bounds.height - countHeight) / 2

            countBackgroundLayer.frame = CGRect(x: countX, y: countY, width: countWidth, height: countHeight)
            countField.frame = CGRect(x: countX, y: countY,
                                       width: countWidth, height: countHeight)

            let labelMaxX = countX - Self.countToLabelGap
            labelField.frame = CGRect(x: labelX, y: (bounds.height - labelHeight) / 2,
                                       width: max(0, labelMaxX - labelX), height: labelHeight)
        } else {
            // No badge, no mosaic — label fills the full trailing range.
            labelField.frame = CGRect(x: labelX, y: (bounds.height - labelHeight) / 2,
                                       width: max(0, trailingX - labelX), height: labelHeight)
        }

        CATransaction.commit()
    }

    // MARK: - Width measurement

    /// Pure measurement helper. Called by `TabStrip.refreshChipWidth(for:)`
    /// once per chip when the title / color / member count / collapsed
    /// flag changes; the result is cached in `TabStrip.chipFullWidths`
    /// and fed to the layout engine via `TabStripLayoutInput.chipFullWidths`.
    ///
    /// - Parameters:
    ///   - title: rendered group title (`group.displayTitle(memberCount:)`).
    ///   - hasUserSetTitle: drives count-badge visibility in expanded state.
    ///     Ignored when `isCollapsed` is true — the mosaic always wins over
    ///     both the badge and the bare-label paths.
    ///   - memberCount: drives count-badge digit width in expanded state.
    ///   - isCollapsed: when true, reserves mosaic (`TabGroupChipMosaicView.mosaicSize`)
    ///     in place of the count badge — even for unnamed groups, since
    ///     the mosaic is the preview signal.
    static func chipWidth(forTitle title: String,
                              hasUserSetTitle: Bool,
                              memberCount: Int,
                              isCollapsed: Bool) -> CGFloat {
        let labelWidth = (title as NSString)
            .size(withAttributes: [.font: labelFont])
            .width
        let leadingOverhead = leadingPadding + dotSize + dotToLabelGap
        var width = leadingOverhead
                  + ceil(labelWidth) + labelSafetyMargin
                  + labelRightPadding

        if isCollapsed {
            // Mosaic always reserves space when collapsed,
            // independent of hasUserSetTitle.
            width += countToLabelGap + TabGroupChipMosaicView.mosaicSize
        } else if hasUserSetTitle {
            let countString = "\(memberCount)" as NSString
            let countTextWidth = countString
                .size(withAttributes: [.font: countFont])
                .width
            let countWidth = ceil(countTextWidth) + countHorizontalPadding * 2
            width += countToLabelGap + countWidth
        }

        return min(width, maxFullWidth)
    }

    // MARK: - Mouse handling

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Prevent AppKit from treating chip-area mouseDown as a
    /// window-drag handle. The main window has
    /// `isMovableByWindowBackground = true`
    /// (`MainBrowserWindowController.swift`), so without these two
    /// overrides drags on the chip would move the host window.
    /// `acceptsFirstResponder = true` matches `TabItemView` and is
    /// required for AppKit to treat this view as one that "responds
    /// to mouse events" — otherwise the `mouseDownCanMoveWindow`
    /// false return is ignored in the window-drag heuristic.
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownInside = true
        mouseDownLocation = event.locationInWindow
        pendingAction = .click
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownInside else { return }
        let dx = event.locationInWindow.x - mouseDownLocation.x
        switch pendingAction {
        case .click:
            if abs(dx) >= Self.dragActivationThreshold {
                pendingAction = .drag
                onDragStart?(token, event.locationInWindow)
            }
        case .drag:
            onDrag?(token, event.locationInWindow)
        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownInside = false
            pendingAction = .idle
        }
        guard mouseDownInside else { return }
        switch pendingAction {
        case .click:
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p) else { return }
            onClick?(token)
        case .drag:
            onDragEnd?(token, event.locationInWindow)
        case .idle:
            break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        return onMenuRequest?(token)
    }

    // MARK: - Accessibility

    override func accessibilityLabel() -> String? {
        let format = isCollapsed
            ? NSLocalizedString(
                "%@ tab group, %d tabs, collapsed",
                comment: "Tab Groups - VoiceOver label for collapsed horizontal-strip group chip")
            : NSLocalizedString(
                "%@ tab group, %d tabs, expanded",
                comment: "Tab Groups - VoiceOver label for expanded horizontal-strip group chip")
        return String(format: format, color.localizedName, memberCount)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}
