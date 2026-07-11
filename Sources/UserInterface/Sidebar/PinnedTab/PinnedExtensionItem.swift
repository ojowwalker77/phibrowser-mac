// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import SwiftUI

struct PinnedTabItemModel: Hashable {
    let id: String
    let title: String
    let icon: NSImage?
    let tooltip: String?

    init(id: String, title: String, icon: NSImage?, tooltip: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PinnedTabItemModel, rhs: PinnedTabItemModel) -> Bool {
        lhs.id == rhs.id
    }
}

class PinnedExtensionItem: NSCollectionViewItem {
    static var reuseIdentifier: NSUserInterfaceItemIdentifier { .init(rawValue: "\(Self.self)") }

    var itemClicked: ((PinnedTabItemModel, NSView) -> Void)?
    var secondaryItemClicked: ((PinnedTabItemModel) -> Void)?

    private var iconImageView: NSImageView!
    private var backgroundView: HoverableView!
    private var model: PinnedTabItemModel?
    private var badgeHost: BadgeHostingView<BadgeCornerOverlay>?

    override func loadView() {
        view = NSView()
        setupUI()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconImageView.image = nil
        view.toolTip = nil
        model = nil
        // Reorder source hiding must not survive into a reused cell.
        view.alphaValue = 1
        // Neither may a stale selection ring: the drag-start selection can be
        // dropped by the preview's snapshot moves without isSelected ever
        // being reset on this instance.
        isSelected = false
    }

    /// `icon` is the resolved display icon (dynamic setIcon/declarative override
    /// plus disabled graying, see ExtensionManager.iconImage); the model's static
    /// icon is the fallback when no manager was available. The badge is a
    /// self-observing SwiftUI overlay hosted over the icon, so badge changes
    /// update without reloading the item.
    func configure(with model: PinnedTabItemModel,
                   icon: NSImage?,
                   manager: ExtensionManager?) {
        self.model = model
        iconImageView.image = icon ?? model.icon ?? defaultIcon()
        view.toolTip = model.tooltip ?? model.title
        if let manager {
            installBadgeOverlay(manager: manager, extensionId: model.id)
        }
    }

    private func installBadgeOverlay(manager: ExtensionManager, extensionId: String) {
        let root = BadgeCornerOverlay(manager: manager,
                                      extensionId: extensionId,
                                      iconSize: 16)
        if let badgeHost {
            badgeHost.rootView = root
        } else {
            // Pass-through host so the decorative badge never intercepts the
            // cell's clicks / hover (it currently survives only via responder-
            // chain bubbling to backgroundView — fragile).
            let host = BadgeHostingView(rootView: root)
            // Pin to the (larger) backgroundView, not the 16pt icon, so the
            // badge has room to straddle the icon's bottom-right corner without
            // being clipped. BadgeCornerOverlay centers a 16pt region to match
            // the centered iconImageView.
            backgroundView.addSubview(host)
            host.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            badgeHost = host
        }
    }

    override var isSelected: Bool {
        didSet {
            updateSelectedState()
        }
    }
}

// MARK: - UI Setup
private extension PinnedExtensionItem {
    func setupUI() {
        view.wantsLayer = true

        backgroundView = HoverableView()
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 6
        backgroundView.backgroundColor = .sidebarTabHovered
        backgroundView.hoveredColor = .sidebarTabHoveredColorEmphasized
        backgroundView.selectedColor = .sidebarTabSelected
        backgroundView.enableClickAnimation = true
        backgroundView.clickAction = { [weak self] in
            guard let self, let model else { return }
            itemClicked?(model, backgroundView)
        }
        backgroundView.secondaryClickAction = { [weak self] in
            guard let self, let model else { return }
            secondaryItemClicked?(model)
        }

        iconImageView = NSImageView()
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.wantsLayer = true
        iconImageView.layer?.cornerRadius = 4

        view.addSubview(backgroundView)
        backgroundView.addSubview(iconImageView)

        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(2)
        }

        iconImageView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.size.equalTo(CGSize(width: 16, height: 16))
        }
    }

    func updateSelectedState() {
        if isSelected {
            backgroundView.isSelected = true
            backgroundView.layer?.borderWidth = 2
            backgroundView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            backgroundView.isSelected = false
            backgroundView.layer?.borderWidth = 0
            backgroundView.layer?.borderColor = NSColor.clear.cgColor
        }
    }

    func defaultIcon() -> NSImage? {
        NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
    }
}
