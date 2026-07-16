// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Owns the optional, entirely local first-run experience.
///
/// Phi no longer has an authenticated account lifecycle. The browser always
/// runs with one local account, while onboarding is only a lightweight setup
/// flow for layout, browser-data import, and password-manager guidance.
final class OnboardingController {
    enum Phase: Int {
        case layoutSelection = 0
        case importData
        case passwordManager
        case done
    }

    static let shared = OnboardingController()

    private let phaseKey = "PhiOnboardingPhase"
    private(set) var windowController: OnboardingWindowController?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    var phase: Phase {
        get {
            guard UserDefaults.standard.object(forKey: phaseKey) != nil else {
                // Existing DMG users already completed the legacy onboarding.
                // Sharing its profile should not force them through setup again.
                if UserDefaults.standard.integer(forKey: PhiPreferences.phiLoginPhase.rawValue) == 6 {
                    return .done
                }
                return .layoutSelection
            }
            return Phase(rawValue: UserDefaults.standard.integer(forKey: phaseKey)) ?? .layoutSelection
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: phaseKey)
        }
    }

    var isComplete: Bool { phase == .done }

    @MainActor
    func showIfNeeded() {
        guard !isComplete else { return }
        show()
    }

    @MainActor
    func show() {
        if windowController == nil {
            windowController = OnboardingWindowController()
        }

        guard let window = windowController?.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            self?.windowController = nil
        }
    }

    @MainActor
    func close() {
        windowController?.close()
        windowController = nil
    }
}
