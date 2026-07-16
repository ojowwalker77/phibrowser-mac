// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

extension Notification.Name {
    static let onboardingCompleted = Notification.Name("OnboardingCompleted")
}

/// Lightweight local first-run setup. Authentication and cloud-account setup
/// deliberately do not belong in this flow.
final class OnboardingWindowController: NSWindowController {
    private lazy var layoutSelectionViewController: LayoutSelectionViewController = {
        let controller = LayoutSelectionViewController()
        controller.nextClosure = { [weak self] _ in
            OnboardingController.shared.phase = .importData
            self?.setContent(self?.importViewController)
        }
        return controller
    }()

    private lazy var importViewController: ImportFromOtherBrowserViewController = {
        let controller = ImportFromOtherBrowserViewController()
        controller.onCompletion = { [weak self] in
            self?.showPasswordManagerPage()
        }
        controller.nextClosure = { [weak self] _ in
            self?.showPasswordManagerPage()
        }
        return controller
    }()

    private lazy var passwordManagerViewController: PasswordManagerViewController = {
        let controller = PasswordManagerViewController()
        controller.nextClosure = { [weak self] _ in
            self?.finish()
        }
        return controller
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false

        self.init(window: window)
        setContent(viewController(for: OnboardingController.shared.phase))
    }

    private func viewController(for phase: OnboardingController.Phase) -> NSViewController {
        switch phase {
        case .layoutSelection:
            return layoutSelectionViewController
        case .importData:
            return importViewController
        case .passwordManager:
            return passwordManagerViewController
        case .done:
            return layoutSelectionViewController
        }
    }

    private func setContent(_ controller: NSViewController?) {
        guard let controller else { return }
        window?.contentViewController = controller
    }

    private func showPasswordManagerPage() {
        OnboardingController.shared.phase = .passwordManager
        setContent(passwordManagerViewController)
    }

    private func finish() {
        OnboardingController.shared.phase = .done
        close()
        ChromiumLauncher.sharedInstance().bridge?.notifyRebuildMenuAfterLogin()
        NotificationCenter.default.post(name: .onboardingCompleted, object: nil)
    }
}
