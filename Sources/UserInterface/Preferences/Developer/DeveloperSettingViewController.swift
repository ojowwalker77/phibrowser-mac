// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

/// Settings pane for developer tooling (remote debugging, the phi-browser
/// skill installer). Mirrors the host/hosting/SwiftUI split used by the other
/// panes (e.g. Spaces): this `SettingsPane` is the AppKit toolbar entry, the
/// content lives in the SwiftUI `DeveloperSettingsView` hosted by
/// `DeveloperSettingHostingViewController`.
class DeveloperSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier: Settings.PaneIdentifier = .developer
    var paneTitle: String = NSLocalizedString("Developer", comment: "Settings - Tab title for developer tooling")
    // The sibling tabs use 32×32 template PDF assets; a bare SF Symbol renders
    // larger than them in the toolbar, so draw the hammer centered into the
    // same 32×32 template canvas to match their size and tinting.
    var toolbarItemIcon: NSImage = {
        guard let symbol = NSImage(systemSymbolName: "hammer",
                                   accessibilityDescription: "developer")?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular)) else {
            return NSImage()
        }
        let canvas = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            let size = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - size.width) / 2,
                                   y: (rect.height - size.height) / 2,
                                   width: size.width, height: size.height))
            return true
        }
        canvas.isTemplate = true
        return canvas
    }()
    let hostingController = DeveloperSettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
