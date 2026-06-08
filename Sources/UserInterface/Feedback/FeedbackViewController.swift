// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

@MainActor
class FeedbackViewController: NSViewController {
    let hostWindowController: MainBrowserWindowController
    
    private let viewModel = FeedbackViewModel()
    
    private lazy var feedbackView: FeedbackView = {
        // Pass the viewModel to the View
        let view = FeedbackView(viewModel: viewModel) { [weak self] in
            guard let self else { return }
            // onPrivacyPolicyTap
            hostWindowController.browserState.openTab("https://phibrowser.com/privacy/")
            hostWindowController.window?.orderFront(nil)
        } onTermsOfServiceTap: { [weak self] in
            guard let self else { return }
            hostWindowController.browserState.openTab("https://phibrowser.com/terms-of-service/")
            hostWindowController.window?.orderFront(nil)
        } onCancel: { [weak self] in
            guard let self else { return }
            closeWindow()
        } onSend: { [weak self] in
            guard let self else { return }
            submitFeedback()
        }
        return view
    }()
    
    private lazy var feedbackHosting = ThemedHostingController(rootView: feedbackView)
    
    init(host: MainBrowserWindowController) {
        self.hostWindowController = host
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(feedbackHosting.view)
        feedbackHosting.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 520, height: 580))
        }
        
        if let tab = hostWindowController.browserState.focusingTab {
            updateActiveTabURL(URLProcessor.phiBrandEnsuredUrlString(tab.url ?? ""))
            viewModel.pageTitle = tab.title
        }
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
    }
    
    func updateActiveTabURL(_ string: String?) {
        // Update ViewModel directly.
        // Since FeedbackView observes this viewModel, it will update UI.
        DispatchQueue.main.async {
            self.viewModel.urlString = string ?? ""
        }
    }

    private func refreshFeedbackContext() {
        if let tab = hostWindowController.browserState.focusingTab {
            viewModel.urlString = URLProcessor.phiBrandEnsuredUrlString(tab.url ?? "")
            viewModel.pageTitle = tab.title
        }
        viewModel.componentVersions = hostWindowController.browserState.extensionManager.phiExtensionVersions
    }

    private func submitFeedback() {
        guard viewModel.canSend else { return }

        refreshFeedbackContext()
        viewModel.isSubmitting = true

        let windowId = Int64(hostWindowController.browserState.windowId)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let chromiumSystemLogsText = await fetchChromiumSystemLogsText(windowId: windowId)

            do {
                try viewModel.enqueueFeedback(chromiumSystemLogsText: chromiumSystemLogsText)
                closeWindow()
            } catch {
                AppLogError("Feedback V2 enqueue failed: \(error.localizedDescription)")
                viewModel.localSaveError = error.localizedDescription
            }

            viewModel.isSubmitting = false
        }
    }

    private func fetchChromiumSystemLogsText(windowId: Int64) async -> String? {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogWarn("Feedback V2 Chromium system logs skipped because the bridge is unavailable")
            return nil
        }

        return await withCheckedContinuation { continuation in
            bridge.getFeedbackSystemLogsText(withWindowId: windowId) { text in
                if text == nil {
                    AppLogWarn("Feedback V2 Chromium system logs skipped because Chromium returned no text")
                }
                continuation.resume(returning: text)
            }
        }
    }
    
    private func closeWindow() {
        view.window?.close()
    }
}
