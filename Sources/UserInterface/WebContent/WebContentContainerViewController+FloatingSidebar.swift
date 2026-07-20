// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit

extension WebContentContainerViewController {
    static let floatingSidebarDefaultWidth: CGFloat = MainSplitViewController.leftItemMinWidth
    static let floatingSidebarTriggerWidth: CGFloat = 10
    static let floatingSidebarHideDelay: TimeInterval = 0.12
    static let floatingSidebarMinimumVisibleDuration: TimeInterval = 0.5
    static let floatingSidebarInset: CGFloat = 5
    static let floatingSidebarShowDuration: TimeInterval = 0.15
    static let floatingSidebarHideDuration: TimeInterval = 0.15

    var currentFloatingWidth: CGFloat {
        // The floating panel only appears while the sidebar is collapsed (sidebarWidth == 0),
        // so we always rely on the cached width captured before collapse.
        if lastKnownSidebarWidth > 0 {
            return lastKnownSidebarWidth
        }
        return Self.floatingSidebarDefaultWidth
    }

    var floatingSidebarHiddenOffset: CGFloat {
        let distance = currentFloatingWidth + Self.floatingSidebarInset
        return PhiPreferences.GeneralSettings.loadSidebarPosition() == .left ? -distance : distance
    }

    func setupFloatingSidebarTrigger() {
        floatingSidebarTriggerView.onMouseEntered = { [weak self] event in
            guard let self else { return }
            isPointerInsideFloatingSidebarTrigger = true
            let enterPoint = floatingSidebarTriggerView.convert(event.locationInWindow, from: nil)
            let enteredFromContent: Bool
            if PhiPreferences.GeneralSettings.loadSidebarPosition() == .left {
                enteredFromContent = enterPoint.x >= (Self.floatingSidebarTriggerWidth * 0.5)
            } else {
                enteredFromContent = enterPoint.x <= (Self.floatingSidebarTriggerWidth * 0.5)
            }
            floatingSidebarShownFromContentSide = enteredFromContent
            showFloatingSidebar()
        }

        floatingSidebarTriggerView.onMouseExited = { [weak self] _ in
            guard let self else { return }
            isPointerInsideFloatingSidebarTrigger = false
            scheduleFloatingSidebarHide()
        }
    }

    func shouldEnableFloatingSidebar() -> Bool {
        guard let state = browserState else { return false }
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        return layoutMode != .comfortable && state.sidebarCollapsed
    }

    func ensureFloatingSidebarIfNeeded() {
        guard floatingSidebarContainerView == nil else { return }
        guard let state = browserState else { return }

        let floatingSidebarVC = FloatingSidebarViewController(browserState: state)

        let interactionContainerView = MouseTrackingAreaView()
        interactionContainerView.onMouseEntered = { [weak self] _ in
            guard let self else { return }
            refreshFloatingSidebarPointerState()
            if !isPointerInsideFloatingSidebarTrigger && floatingSidebarShownFromContentSide {
                floatingSidebarShownFromContentSide = false
            }
            if isPointerInsideFloatingSidebar {
                cancelFloatingSidebarHide()
            }
        }

        interactionContainerView.onMouseExited = { [weak self] _ in
            guard let self else { return }
            isPointerInsideFloatingSidebar = false
            scheduleFloatingSidebarHide()
        }

        let panelContentView = NSView()
        panelContentView.wantsLayer = true
        panelContentView.layer?.cornerCurve = .continuous
        panelContentView.layer?.cornerRadius = 14
        panelContentView.layer?.masksToBounds = true
        panelContentView.phiLayer?.setBorderColor(.border)
        panelContentView.layer?.borderWidth = 1

        addChild(floatingSidebarVC)
        panelContentView.addSubview(floatingSidebarVC.view)
        floatingSidebarVC.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let panelVisualContainer = panelContentView

        interactionContainerView.addSubview(panelVisualContainer)

        // Sit above `outerBorderLayer` (zPosition = contentOuterBorder) so the
        // unified content-border stroke doesn't paint on top of the panel
        // when it slides in over the web content.
        interactionContainerView.wantsLayer = true
        interactionContainerView.layer?.zPosition = WebContentContainerViewController.LayerZIndex.floatingSidebar

        view.addSubview(interactionContainerView, positioned: .above, relativeTo: nil)
        floatingSidebarPanelContentView = panelVisualContainer
        floatingSidebarContainerView = interactionContainerView
        updateFloatingSidebarPlacement()
        view.layoutSubtreeIfNeeded()
        interactionContainerView.isHidden = true
        interactionContainerView.alphaValue = 1

        floatingSidebarViewController = floatingSidebarVC
        floatingSidebarVC.setContentActive(shouldEnableFloatingSidebar())
    }

    func updateFloatingSidebarPlacement() {
        let position = PhiPreferences.GeneralSettings.loadSidebarPosition()

        floatingSidebarTriggerView.snp.remakeConstraints { make in
            if position == .left {
                make.leading.equalToSuperview()
            } else {
                make.trailing.equalToSuperview()
            }
            make.top.bottom.equalToSuperview()
            make.width.equalTo(Self.floatingSidebarTriggerWidth)
        }

        guard let panel = floatingSidebarContainerView,
              let panelContent = floatingSidebarPanelContentView else { return }

        panelContent.snp.remakeConstraints { make in
            make.top.bottom.equalToSuperview()
            if position == .left {
                make.leading.equalToSuperview().offset(Self.floatingSidebarInset)
                make.trailing.equalToSuperview()
            } else {
                make.leading.equalToSuperview()
                make.trailing.equalToSuperview().offset(-Self.floatingSidebarInset)
            }
        }

        panel.snp.remakeConstraints { make in
            let horizontalOffset = panel.isHidden ? floatingSidebarHiddenOffset : 0
            if position == .left {
                floatingSidebarHorizontalConstraint = make.leading.equalToSuperview()
                    .offset(horizontalOffset).constraint
            } else {
                floatingSidebarHorizontalConstraint = make.trailing.equalToSuperview()
                    .offset(horizontalOffset).constraint
            }
            make.top.equalToSuperview().offset(Self.floatingSidebarInset)
            make.bottom.equalToSuperview().offset(-Self.floatingSidebarInset)
            floatingSidebarWidthConstraint = make.width
                .equalTo(currentFloatingWidth + Self.floatingSidebarInset).constraint
        }
        view.layoutSubtreeIfNeeded()
    }

    /// A Space switch driven from this panel orders the window out with the
    /// panel still up (it hosts the push-in slide until the swap lands).
    /// Hide it once the window is actually off screen — the pointer-driven
    /// hide can't fire on a hidden window — so the window doesn't re-surface
    /// later with a stale panel. Idempotent; re-attempted on every show in
    /// case the view wasn't in a window at panel-creation time.
    private func ensureFloatingSidebarOcclusionObserver() {
        guard floatingSidebarOcclusionObserver == nil, let window = view.window else { return }
        floatingSidebarOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.view.window?.isVisible == false else { return }
            self.hideFloatingSidebar(animated: false)
        }
    }

    func updateFloatingSidebarWidth() {
        floatingSidebarWidthConstraint?.update(offset: currentFloatingWidth + Self.floatingSidebarInset)
    }

    func updateFloatingSidebarAvailability() {
        let shouldEnable = shouldEnableFloatingSidebar()

        floatingSidebarEnableWorkItem?.cancel()
        floatingSidebarEnableWorkItem = nil

        if !shouldEnable {
            floatingSidebarTriggerView.isHidden = true
            isPointerInsideFloatingSidebar = false
            isPointerInsideFloatingSidebarTrigger = false
            floatingSidebarShownFromContentSide = false
            floatingSidebarViewController?.setContentActive(false)
            hideFloatingSidebar(animated: false)
        } else if floatingSidebarTriggerView.isHidden {
            floatingSidebarViewController?.setContentActive(true)
            // Delay enabling trigger to avoid activation during sidebar collapse animation.
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.shouldEnableFloatingSidebar() else { return }
                self.floatingSidebarTriggerView.isHidden = false
            }
            floatingSidebarEnableWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        }
    }

    func showFloatingSidebar() {
        guard shouldEnableFloatingSidebar() else { return }
        ensureFloatingSidebarIfNeeded()
        ensureFloatingSidebarOcclusionObserver()
        cancelFloatingSidebarHide()

        guard let panel = floatingSidebarContainerView else { return }
        guard panel.isHidden else { return }

        // Ensure panel starts offscreen before sliding in.
        floatingSidebarHorizontalConstraint?.update(offset: floatingSidebarHiddenOffset)
        view.layoutSubtreeIfNeeded()
        panel.isHidden = false
        floatingSidebarLastShownAt = Date()
        floatingSidebarViewController?.refreshFloatingTrafficLights()

        // Handle the case where the panel appears under a stationary cursor and no mouseEntered is emitted.
        refreshFloatingSidebarPointerState()
        if isPointerInsideFloatingSidebar {
            cancelFloatingSidebarHide()
        }

        floatingSidebarHorizontalConstraint?.update(offset: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.floatingSidebarShowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.view.layoutSubtreeIfNeeded()
        }
    }

    func hideFloatingSidebar(animated: Bool) {
        cancelFloatingSidebarHide()
        guard let panel = floatingSidebarContainerView else { return }
        guard panel.isHidden == false else { return }
        // A forced hide (sidebar expanding, window ordering out) takes the
        // create-Space form down with the panel; without this the form's
        // `isCreatingSpace` pin on the slot would outlive the visible form.
        // Pointer-driven hides are already blocked while the form is up
        // (see scheduleFloatingSidebarHide), so this only fires on forced paths.
        floatingSidebarViewController?.dismissCreateSpaceOverlay()
        floatingSidebarHorizontalConstraint?.update(offset: floatingSidebarHiddenOffset)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.floatingSidebarHideDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                context.allowsImplicitAnimation = true
                self.view.layoutSubtreeIfNeeded()
            } completionHandler: {
                panel.isHidden = true
                self.floatingSidebarLastShownAt = nil
                self.floatingSidebarShownFromContentSide = false
            }
        } else {
            view.layoutSubtreeIfNeeded()
            panel.isHidden = true
            floatingSidebarLastShownAt = nil
            floatingSidebarShownFromContentSide = false
        }
    }

    func scheduleFloatingSidebarHide() {
        cancelFloatingSidebarHide()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The inline create-Space form pins the panel open: a pointer
            // excursion outside the panel must not tear the form down
            // mid-input. The pin lifts when the form closes (its dismiss
            // re-runs this scheduling).
            guard floatingSidebarViewController?.hasCreateSpaceOverlay != true else { return }
            refreshFloatingSidebarPointerState()
            guard isPointerInsideFloatingSidebar == false else { return }
            guard isPointerInsideFloatingSidebarTrigger == false else { return }
            if floatingSidebarShownFromContentSide, isMouseBeyondFloatingSidebarOuterEdge() {
                return
            }
            hideFloatingSidebar(animated: true)
        }
        floatingSidebarHideWorkItem = workItem
        let minimumVisibleRemaining: TimeInterval
        if let shownAt = floatingSidebarLastShownAt {
            let visibleElapsed = Date().timeIntervalSince(shownAt)
            minimumVisibleRemaining = max(0, Self.floatingSidebarMinimumVisibleDuration - visibleElapsed)
        } else {
            minimumVisibleRemaining = 0
        }
        let delay = max(Self.floatingSidebarHideDelay, minimumVisibleRemaining)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelFloatingSidebarHide() {
        floatingSidebarHideWorkItem?.cancel()
        floatingSidebarHideWorkItem = nil
    }

    func refreshFloatingSidebarPointerState() {
        if let panel = floatingSidebarContainerView, panel.isHidden == false {
            isPointerInsideFloatingSidebar = isMouseInsideFloatingSidebarVisibleRegion()
        } else {
            isPointerInsideFloatingSidebar = false
        }
        if floatingSidebarTriggerView.isHidden == false {
            isPointerInsideFloatingSidebarTrigger = isMouseInside(view: floatingSidebarTriggerView)
        } else {
            isPointerInsideFloatingSidebarTrigger = false
        }
    }

    func isMouseInside(view targetView: NSView) -> Bool {
        guard let window = targetView.window else { return false }
        let mouseLocationInWindow = window.mouseLocationOutsideOfEventStream
        let locationInView = targetView.convert(mouseLocationInWindow, from: nil)
        return targetView.bounds.contains(locationInView)
    }

    func isMouseBeyondFloatingSidebarOuterEdge() -> Bool {
        guard let panel = floatingSidebarContainerView, panel.isHidden == false else { return false }
        guard let window = panel.window else { return false }
        let mouseLocationInWindow = window.mouseLocationOutsideOfEventStream
        guard let panelContent = floatingSidebarPanelContentView else { return false }
        let contentFrameInWindow = panelContent.convert(panelContent.bounds, to: nil)

        let withinY = (mouseLocationInWindow.y >= contentFrameInWindow.minY)
            && (mouseLocationInWindow.y <= contentFrameInWindow.maxY)
        guard withinY else { return false }
        if PhiPreferences.GeneralSettings.loadSidebarPosition() == .left {
            return mouseLocationInWindow.x < contentFrameInWindow.minX
        }
        return mouseLocationInWindow.x > contentFrameInWindow.maxX
    }

    func isMouseInsideFloatingSidebarVisibleRegion() -> Bool {
        guard let panel = floatingSidebarContainerView, panel.isHidden == false,
              let panelContent = floatingSidebarPanelContentView else { return false }
        return isMouseInside(view: panelContent)
    }
}

final class MouseTrackingAreaView: NSView {
    var onMouseEntered: ((NSEvent) -> Void)?
    var onMouseExited: ((NSEvent) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseEntered?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?(event)
    }
}
