// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

final class GroupOverviewViewController: NSViewController {
    private let browserState: BrowserState
    private let groupToken: String
    private var hostingController: ThemedHostingController<GroupOverviewView>?
    private var keyDownMonitor: Any?

    init(browserState: BrowserState, groupToken: String) {
        self.browserState = browserState
        self.groupToken = groupToken
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installSwiftUIView()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        installKeyDownMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeKeyDownMonitor()
    }

    deinit {
        removeKeyDownMonitor()
    }

    private func installSwiftUIView() {
        let viewModel = GroupOverviewViewModel(browserState: browserState,
                                               groupToken: groupToken)
        let overview = GroupOverviewView(
            viewModel: viewModel,
            selectTab: { [weak browserState] tab in
                browserState?.clearGroupOverview()
                tab.webContentWrapper?.setAsActiveTab()
            },
            closeTab: { tab in
                tab.close()
            },
            createTab: { [weak browserState] in
                guard let browserState else { return }
                browserState.createNewTabAtEndOfCurrentOverviewGroup()
            },
            closeOverview: { [weak browserState] in
                browserState?.clearGroupOverview()
            }
        )
        let hosting = ThemedHostingController(rootView: overview,
                                              themeSource: browserState.themeContext)
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController = hosting
    }

    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            guard event.window == self.view.window else { return event }
            self.browserState.clearGroupOverview()
            return nil
        }
    }

    private func removeKeyDownMonitor() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
    }
}
