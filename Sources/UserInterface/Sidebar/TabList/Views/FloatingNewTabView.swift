//
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.
    

import Cocoa

class FloatingNewTabView: ColoredVisualEffectView {
    let cellView = NewTabButtonCellView(frame: .zero)
    private let separatorView = NSView()
    private var trackingArea: NSTrackingArea?
    var hoverStateChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func layout() {
        super.layout()
        cellView.frame = bounds
        separatorView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
        updateHoverStateForCurrentMouseLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hoverStateChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverStateChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let cellPoint = cellView.convert(point, from: self)
        return cellView.hitTest(cellPoint) ?? self
    }

    override func mouseDown(with event: NSEvent) {
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        cellView.clickAction?()
    }

    private func setupViews() {
        themedBackgroundColor = .windowOverlayBackground
        material = .fullScreenUI
        addSubview(cellView)

        separatorView.wantsLayer = true
        separatorView.phiLayer?.setBackgroundColor(.separator)
        addSubview(separatorView)
    }

    private func updateHoverStateForCurrentMouseLocation() {
        guard let window else {
            hoverStateChanged?(false)
            return
        }

        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        hoverStateChanged?(bounds.contains(localPoint))
    }
}
