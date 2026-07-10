// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class CustomTooltipTests: XCTestCase {
    @MainActor
    private final class ManualScheduler {
        private final class ScheduledAction {
            let delay: TimeInterval
            let action: @MainActor () -> Void
            var isCancelled = false

            init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
                self.delay = delay
                self.action = action
            }
        }

        private var actions: [ScheduledAction] = []

        var pendingDelays: [TimeInterval] {
            actions.filter { !$0.isCancelled }.map(\.delay)
        }

        func schedule(
            delay: TimeInterval,
            action: @escaping @MainActor () -> Void
        ) -> AnyCancellable {
            let scheduledAction = ScheduledAction(delay: delay, action: action)
            actions.append(scheduledAction)
            return AnyCancellable {
                MainActor.assumeIsolated {
                    scheduledAction.isCancelled = true
                }
            }
        }

        func fireNext() {
            while !actions.isEmpty {
                let scheduledAction = actions.removeFirst()
                guard !scheduledAction.isCancelled else { continue }
                scheduledAction.action()
                return
            }
        }
    }

    private final class RecordingPresenter: CustomTooltipPresenting {
        private let panelToken = NSObject()
        private let hostingViewToken = NSObject()

        private(set) var isVisible = false
        private(set) var presentCount = 0
        private(set) var dismissCount = 0
        private(set) var lastThemeProvider: ThemeStateProvider?

        var surfaceIdentifiers: (panel: ObjectIdentifier, hostingView: ObjectIdentifier)? {
            (ObjectIdentifier(panelToken), ObjectIdentifier(hostingViewToken))
        }

        func present(
            content: AnyView,
            anchorScreenRect: CGRect,
            screen: NSScreen?,
            themeProvider: ThemeStateProvider
        ) {
            isVisible = true
            presentCount += 1
            lastThemeProvider = themeProvider
        }

        func dismiss() {
            isVisible = false
            dismissCount += 1
        }
    }

    func testWindowReusesOneControllerAndIsolatesOtherWindows() {
        let firstWindow = makeWindow().window
        let secondWindow = makeWindow().window

        XCTAssertTrue(firstWindow.customTooltipController === firstWindow.customTooltipController)
        XCTAssertFalse(firstWindow.customTooltipController === secondWindow.customTooltipController)
    }

    func testDifferentViewsReuseRealPanelAndHostingView() throws {
        let fixture = makeWindow()
        let secondHost = NSView(frame: CGRect(x: 220, y: 40, width: 120, height: 32))
        fixture.window.contentView?.addSubview(secondHost)
        let scheduler = ManualScheduler()
        var currentMouseLocation = fixture.mouseLocation
        let controller = CustomTooltipController(
            window: fixture.window,
            scheduler: scheduler.schedule,
            mouseLocation: { currentMouseLocation },
            isEligibleForPresentation: { _ in true }
        )
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        let firstSurface = try XCTUnwrap(controller.surfaceIdentifiers)
        controller.pointerExited(ownerID: firstOwnerID)

        let secondRectInWindow = secondHost.convert(secondHost.bounds, to: nil)
        let secondScreenRect = fixture.window.convertToScreen(secondRectInWindow)
        currentMouseLocation = CGPoint(x: secondScreenRect.midX, y: secondScreenRect.midY)
        controller.pointerEntered(
            ownerID: secondOwnerID,
            anchorView: secondHost,
            content: AnyView(Text("Second")),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        let secondSurface = try XCTUnwrap(controller.surfaceIdentifiers)

        XCTAssertTrue(fixture.host !== secondHost)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.activeOwnerID, secondOwnerID)
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
        XCTAssertEqual(firstSurface.panel, secondSurface.panel)
        XCTAssertEqual(firstSurface.hostingView, secondSurface.hostingView)
        controller.dismissAll()
    }

    func testInitialHoverUsesConfiguredDelay() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Delayed")),
            configuration: CustomTooltipConfiguration(showDelay: 0.75, displayDuration: nil)
        )

        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(controller.pendingOwnerID, ownerID)
        XCTAssertEqual(scheduler.pendingDelays, [0.75])

        scheduler.fireNext()

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(controller.activeOwnerID, ownerID)
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testPointerExitCancelsPendingPresentation() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Cancelled")),
            configuration: CustomTooltipConfiguration(showDelay: 1, displayDuration: nil)
        )
        controller.pointerExited(ownerID: ownerID)
        scheduler.fireNext()

        XCTAssertNil(controller.pendingOwnerID)
        XCTAssertNil(controller.activeOwnerID)
        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(presenter.presentCount, 0)
    }

    func testWarmHandoffShowsNextViewImmediatelyAndReusesSurface() throws {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        let firstSurface = try XCTUnwrap(controller.surfaceIdentifiers)
        controller.pointerExited(ownerID: firstOwnerID)

        XCTAssertFalse(presenter.isVisible, "Leaving the hosting view must hide synchronously.")

        controller.pointerEntered(
            ownerID: secondOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("Second")),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        let secondSurface = try XCTUnwrap(controller.surfaceIdentifiers)

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(controller.activeOwnerID, secondOwnerID)
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
        XCTAssertEqual(firstSurface.panel, secondSurface.panel)
        XCTAssertEqual(firstSurface.hostingView, secondSurface.hostingView)
    }

    func testStaleExitCannotDismissNewOwner() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()

        controller.pointerEntered(
            ownerID: firstOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("First")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        controller.pointerEntered(
            ownerID: secondOwnerID,
            anchorView: fixture.host,
            content: AnyView(Text("Second")),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        controller.pointerExited(ownerID: firstOwnerID)

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(controller.activeOwnerID, secondOwnerID)
        XCTAssertEqual(presenter.presentCount, 2)
    }

    func testConfiguredDisplayDurationHidesTooltip() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Timed")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: 2.5)
        )

        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(scheduler.pendingDelays, [2.5])

        scheduler.fireNext()

        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(controller.activeOwnerID)
    }

    func testUpdatingPendingShowDelayReschedulesPresentation() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Pending")),
            configuration: CustomTooltipConfiguration(showDelay: 5, displayDuration: nil)
        )
        controller.update(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Updated")),
            configuration: CustomTooltipConfiguration(showDelay: 1, displayDuration: nil)
        )

        XCTAssertEqual(scheduler.pendingDelays, [1])
        scheduler.fireNext()
        XCTAssertTrue(presenter.isVisible)
    }

    func testUpdatingVisibleDisplayDurationReschedulesDismissal() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )
        let ownerID = UUID()

        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Visible")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        controller.update(
            ownerID: ownerID,
            anchorView: fixture.host,
            content: AnyView(Text("Updated")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: 3)
        )

        XCTAssertEqual(scheduler.pendingDelays, [3])
        scheduler.fireNext()
        XCTAssertFalse(presenter.isVisible)
    }

    func testWindowResignCancelsPendingAndHidesVisibleTooltip() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Visible")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        XCTAssertTrue(presenter.isVisible)

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: fixture.window
        )

        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(controller.activeOwnerID)

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Pending")),
            configuration: CustomTooltipConfiguration(showDelay: 1, displayDuration: nil)
        )
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: fixture.window
        )
        scheduler.fireNext()

        XCTAssertNil(controller.pendingOwnerID)
        XCTAssertEqual(presenter.presentCount, 1)
    }

    func testApplicationResignHidesTooltip() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Visible")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )

        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(controller.activeOwnerID)
    }

    func testOtherWindowResignDoesNotHideTooltip() {
        let fixture = makeWindow()
        let otherWindow = makeWindow().window
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Visible")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: otherWindow
        )

        XCTAssertTrue(presenter.isVisible)
    }

    func testControllerUsesSourceWindowThemeProvider() {
        let fixture = makeWindow()
        let scheduler = ManualScheduler()
        let presenter = RecordingPresenter()
        let themeContext = BrowserThemeContext(
            configuration: BrowserThemeConfiguration(
                currentTheme: Theme(id: "tooltip-theme", name: "Tooltip"),
                userAppearanceChoice: .dark,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        )
        let controller = makeController(
            fixture: fixture,
            scheduler: scheduler,
            presenter: presenter,
            themeProvider: { _ in themeContext }
        )

        controller.pointerEntered(
            ownerID: UUID(),
            anchorView: fixture.host,
            content: AnyView(Text("Themed")),
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )

        XCTAssertTrue(presenter.lastThemeProvider === themeContext)
        XCTAssertEqual(presenter.lastThemeProvider?.currentAppearance, .dark)
    }

    func testAppKitExtensionReusesRegistrationAndSuppressesNativeTooltip() throws {
        let fixture = makeWindow()
        let originalTrackingAreaCount = fixture.host.trackingAreas.count
        fixture.host.toolTip = "Native"

        fixture.host.setCustomTooltip(
            "Custom",
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        let firstRegistration = try XCTUnwrap(fixture.host.customTooltipRegistration)

        XCTAssertNil(fixture.host.toolTip)
        XCTAssertEqual(fixture.host.trackingAreas.count, originalTrackingAreaCount + 1)

        fixture.host.setCustomTooltip(
            "Updated custom",
            configuration: CustomTooltipConfiguration(showDelay: 0, displayDuration: nil)
        )
        XCTAssertTrue(firstRegistration === fixture.host.customTooltipRegistration)
        XCTAssertEqual(fixture.host.trackingAreas.count, originalTrackingAreaCount + 1)

        fixture.host.toolTip = "Updated native"
        XCTAssertNil(fixture.host.toolTip)

        fixture.host.removeCustomTooltip()

        XCTAssertNil(fixture.host.customTooltipRegistration)
        XCTAssertEqual(fixture.host.toolTip, "Updated native")
    }

    func testSwiftUIModifierInstallsSharedAppKitRegistration() {
        let fixture = makeWindow()
        let swiftUIView = Text("Host")
            .frame(width: 120, height: 32)
            .help("Native")
            .customTooltip("Custom")
        let hostingView = NSHostingView(rootView: swiftUIView)
        hostingView.frame = CGRect(x: 20, y: 20, width: 120, height: 32)
        fixture.window.contentView?.addSubview(hostingView)
        hostingView.layoutSubtreeIfNeeded()

        let registration = allSubviews(of: hostingView)
            .compactMap(\.customTooltipRegistration)
            .first

        XCTAssertNotNil(registration)
    }

    func testSwiftUICustomTooltipSuppressesAdjacentHelpInEitherOrder() {
        let helpBeforeCustom = Text("Host")
            .help("Native")
            .customTooltip("Custom")
        let helpAfterCustom = Text("Host")
            .customTooltip("Custom")
            .help("Native")

        XCTAssertTrue(helpBeforeCustom.suppressesNativeHelp)
        XCTAssertTrue(helpAfterCustom.suppressesNativeHelp)
    }

    private typealias WindowFixture = (window: NSWindow, host: NSView, mouseLocation: CGPoint)

    private func makeWindow() -> WindowFixture {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        let host = NSView(frame: CGRect(x: 40, y: 40, width: 120, height: 32))
        contentView.addSubview(host)
        window.contentView = contentView

        let rectInWindow = host.convert(host.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        return (window, host, CGPoint(x: screenRect.midX, y: screenRect.midY))
    }

    private func makeController(
        fixture: WindowFixture,
        scheduler: ManualScheduler,
        presenter: RecordingPresenter,
        themeProvider: CustomTooltipController.ThemeProviderResolver? = nil
    ) -> CustomTooltipController {
        CustomTooltipController(
            window: fixture.window,
            presenter: presenter,
            scheduler: scheduler.schedule,
            mouseLocation: { fixture.mouseLocation },
            isEligibleForPresentation: { _ in true },
            themeProvider: themeProvider
        )
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}
