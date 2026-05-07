// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// "Flag"-shaped chip rendered to the left of each visible group's first
/// member tab on the horizontal strip. Renders one of two modes
/// (`ChipMode.full` / `.compact`) — the mode is decided by
/// `TabStripLayoutEngine`, not by the chip itself, so chip width is
/// consistent with the engine's tab-width allocation in the same pass.
///
/// Visual structure:
///   ┌─────────────────────────────────┐
///   │ ▌ Work · 3 tabs           [3]   │  full
///   └─────────────────────────────────┘
///   ▌▒▒  (compact: 4pt bar + 16pt color swatch + 4pt right pad = 24pt)
///
/// Click + right-click + hover handling lives in a separate task; this
/// task is rendering-only.
final class TabGroupChipView: NSView {
    // MARK: - Metrics

    static let height: CGFloat = 22
    static let cornerRadius: CGFloat = 4
    static let barWidth: CGFloat = 4
    static let labelLeftPadding: CGFloat = 7
    static let labelRightPadding: CGFloat = 6  // tightened to leave room for chevron
    static let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let countFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    static let countHorizontalPadding: CGFloat = 6
    static let countVerticalPadding: CGFloat = 1
    static let countToLabelGap: CGFloat = 6
    static let maxFullWidth: CGFloat = 140
    /// Compact mode: bar + swatch + 4pt right pad.
    static let compactWidth: CGFloat = 24
    static let compactSwatchWidth: CGFloat = 16
    static let compactRightPad: CGFloat = 4

    // Chevron — collapse/expand state indicator. Shown in full mode at
    // the trailing edge (after label / count), and overlaid on the
    // color swatch in compact mode (replacing it visually) so the
    // collapsed/expanded state is visible regardless of chip width.
    static let chevronSize: CGFloat = 9
    static let chevronToContentGap: CGFloat = 4

    // MARK: - Callbacks (set by TabStrip)

    /// Called when the chip is clicked (mouseUp inside bounds, no drag,
    /// not a right-click). `TabStrip` uses this to fire
    /// `bridge.updateTabGroupCollapsed(...)`.
    var onClick: ((String) -> Void)?

    /// Called to populate the right-click menu. `TabStrip` reuses
    /// `TabGroupSidebarItem.makeContextMenu` here. Returns nil → no menu.
    var onMenuRequest: ((String) -> NSMenu?)?

    // MARK: - Hover state

    private var isHovered: Bool = false {
        didSet {
            guard oldValue != isHovered else { return }
            applyAppearance()
        }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var mouseDownInside: Bool = false

    // MARK: - Data

    private(set) var token: String = ""
    private(set) var color: GroupColor = .grey
    private(set) var displayTitle: String = ""
    private(set) var memberCount: Int = 0
    private(set) var hasUserSetTitle: Bool = false
    private(set) var mode: ChipMode = .full
    private(set) var isCollapsed: Bool = false

    // MARK: - Subviews / sublayers

    private let backgroundLayer = CALayer()
    private let barLayer = CALayer()
    private let compactSwatchLayer = CALayer()
    private let labelField: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.isEditable = false
        tf.isSelectable = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.font = TabGroupChipView.labelFont
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
    private let chevronImageView: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyDown
        iv.translatesAutoresizingMaskIntoConstraints = true
        return iv
    }()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.cornerRadius

        layer?.addSublayer(backgroundLayer)
        layer?.addSublayer(barLayer)
        layer?.addSublayer(compactSwatchLayer)
        layer?.addSublayer(countBackgroundLayer)

        // Suppress implicit animations for layers we manage explicitly.
        backgroundLayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        barLayer.actions         = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        compactSwatchLayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        countBackgroundLayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                        "cornerRadius": NSNull()]

        addSubview(labelField)
        addSubview(countField)
        addSubview(chevronImageView)

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
        mode: ChipMode,
        isCollapsed: Bool
    ) {
        self.token = token
        self.color = color
        self.displayTitle = displayTitle
        self.memberCount = memberCount
        self.hasUserSetTitle = hasUserSetTitle
        self.mode = mode
        self.isCollapsed = isCollapsed

        labelField.stringValue = displayTitle
        countField.stringValue = "\(memberCount)"

        applyAppearance()
        needsLayout = true
    }

    // MARK: - Appearance

    private func applyAppearance() {
        backgroundLayer.backgroundColor = (isHovered
            ? color.chipHoverTintColor
            : color.chipTintColor).cgColor
        barLayer.backgroundColor = color.nsColor.cgColor
        compactSwatchLayer.backgroundColor = color.chipCompactSwatchColor.cgColor
        countBackgroundLayer.backgroundColor = color.chipHoverTintColor.cgColor
        countBackgroundLayer.cornerRadius = (TabGroupChipView.countFont.pointSize +
                                              Self.countVerticalPadding * 2) / 2.0

        // Chevron points right when collapsed (suggests "click to
        // expand"), down when expanded (suggests "tabs are below /
        // click to collapse"). In full mode the chevron uses
        // secondaryLabelColor so it doesn't compete with the title;
        // in compact mode it uses the saturated group color so the
        // 24pt-wide chip still carries a strong color presence (it
        // replaces the swatch — see layoutCompactMode).
        let symbolName = isCollapsed ? "chevron.right" : "chevron.down"
        let config = NSImage.SymbolConfiguration(pointSize: Self.chevronSize, weight: .semibold)
        chevronImageView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config)
        chevronImageView.contentTintColor = (mode == .compact)
            ? color.nsColor
            : .secondaryLabelColor

        let showLabel = (mode == .full)
        let showCount = (mode == .full) && hasUserSetTitle
        // Compact mode: the chevron stands in for the swatch as the
        // single visible symbol next to the bar. Hiding the swatch
        // keeps the 24pt width unchanged.
        let showCompactSwatch = false

        labelField.isHidden = !showLabel
        countField.isHidden = !showCount
        countBackgroundLayer.isHidden = !showCount
        compactSwatchLayer.isHidden = !showCompactSwatch
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

        backgroundLayer.frame = bounds
        barLayer.frame = CGRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height)

        switch mode {
        case .full:
            layoutFullMode()
        case .compact:
            layoutCompactMode()
        }

        CATransaction.commit()
    }

    private func layoutFullMode() {
        let labelX = Self.barWidth + Self.labelLeftPadding
        let labelHeight = ceil(Self.labelFont.ascender - Self.labelFont.descender + Self.labelFont.leading)

        // Chevron pinned to the trailing edge of the chip.
        let chevronX = bounds.width - Self.labelRightPadding - Self.chevronSize
        let chevronY = (bounds.height - Self.chevronSize) / 2
        chevronImageView.frame = CGRect(x: chevronX, y: chevronY,
                                         width: Self.chevronSize, height: Self.chevronSize)

        if hasUserSetTitle {
            // Count badge sits between the label and the chevron.
            let countString = countField.stringValue as NSString
            let countTextWidth = countString.size(withAttributes: [.font: Self.countFont]).width
            let countWidth = ceil(countTextWidth) + Self.countHorizontalPadding * 2
            let countHeight = Self.countFont.pointSize + Self.countVerticalPadding * 2
            let countX = chevronX - Self.chevronToContentGap - countWidth
            let countY = (bounds.height - countHeight) / 2

            countBackgroundLayer.frame = CGRect(x: countX, y: countY, width: countWidth, height: countHeight)
            countField.frame = CGRect(x: countX, y: countY + Self.countVerticalPadding,
                                       width: countWidth, height: countHeight - Self.countVerticalPadding * 2)

            let labelMaxX = countX - Self.countToLabelGap
            labelField.frame = CGRect(x: labelX, y: (bounds.height - labelHeight) / 2,
                                       width: max(0, labelMaxX - labelX), height: labelHeight)
        } else {
            // No badge — label fills up to the chevron's left edge.
            let labelMaxX = chevronX - Self.chevronToContentGap
            labelField.frame = CGRect(x: labelX, y: (bounds.height - labelHeight) / 2,
                                       width: max(0, labelMaxX - labelX), height: labelHeight)
        }
    }

    private func layoutCompactMode() {
        // Chevron centered in the swatch region (replaces the swatch
        // visually so chip width stays at compactWidth = 24pt).
        let chevronAreaX = Self.barWidth
        let chevronX = chevronAreaX + (Self.compactSwatchWidth - Self.chevronSize) / 2
        let chevronY = (bounds.height - Self.chevronSize) / 2
        chevronImageView.frame = CGRect(x: chevronX, y: chevronY,
                                         width: Self.chevronSize, height: Self.chevronSize)
        // labelField / countField hidden via applyAppearance().
    }

    // MARK: - Width measurement

    /// Pure measurement helper. Called by `TabStrip.refreshChipWidth(for:)`
    /// once per chip when the title / color / member count changes; the
    /// result is cached in `TabStrip.chipFullWidths` and fed to the
    /// layout engine via `TabStripLayoutInput.chipFullWidths`.
    static func fullModeWidth(forTitle title: String,
                              hasUserSetTitle: Bool,
                              memberCount: Int) -> CGFloat {
        let labelWidth = (title as NSString)
            .size(withAttributes: [.font: labelFont])
            .width
        // Trailing edge reserves space for the chevron with the same
        // labelRightPadding gap to the chip's right border.
        let chevronOverhead = chevronToContentGap + chevronSize + labelRightPadding
        var width = barWidth + labelLeftPadding + ceil(labelWidth) + chevronOverhead

        if hasUserSetTitle {
            let countString = "\(memberCount)" as NSString
            let countTextWidth = countString
                .size(withAttributes: [.font: countFont])
                .width
            let countWidth = ceil(countTextWidth) + countHorizontalPadding * 2
            // With badge: + countToLabelGap + countW (count sits
            // between label and the chevron overhead already
            // accounted for above).
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

    override func mouseDown(with event: NSEvent) {
        mouseDownInside = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownInside = false }
        guard mouseDownInside else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        onClick?(token)
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
