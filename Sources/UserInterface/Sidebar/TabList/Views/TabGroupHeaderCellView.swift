// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SnapKit

/// NSTableCellView host for `TabGroupHeaderView` — bridges the
/// `TabGroupSidebarItem` row in NSOutlineView to its SwiftUI rendering.
/// Created lazily by `SidebarTabListViewController.outlineView(_:viewFor:item:)`
/// and reused via `prepareForReuse`. Click-to-collapse routing lands in the
/// next chunk; this chunk is visual-only.
class TabGroupHeaderCellView: SidebarCellView {
    private var hostingView: ThemedHostingView!
    private let viewModel = TabGroupHeaderViewModel()

    private var isDropTargetHighlighted = false
    /// Color of the most recent group config, kept so the drop highlight
    /// can re-derive its tint without going back to the source item.
    private var lastGroupColor: GroupColor = .grey

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        viewModel.cancelSubscriptions()
    }

    private func setupViews() {
        hostingView = ThemedHostingView(rootView: TabGroupHeaderView(viewModel: viewModel))
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func configureAppearance() {
        guard let groupItem = item as? TabGroupSidebarItem,
              let state = MainBrowserWindowControllersManager.shared
                .controller(for: groupItem.windowId)?.browserState
        else { return }
        viewModel.configure(with: groupItem.group, in: state)
        // Capture the color so `applyHighlightVisuals()` can re-derive its
        // tint when the cell is reconfigured (e.g. after a group recolor).
        lastGroupColor = groupItem.group.color
        applyHighlightVisuals()
    }

    /// Toggle drop-target highlight. Mirrors `BookmarkCellView`'s pattern so
    /// the sidebar drop-feedback state machine can drive both cells with
    /// identical call sites.
    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard isDropTargetHighlighted != highlighted else { return }
        isDropTargetHighlighted = highlighted
        applyHighlightVisuals()
    }

    private func applyHighlightVisuals() {
        wantsLayer = true
        if isDropTargetHighlighted {
            // Low-alpha tint of the group color, matching the bookmark
            // folder drop feedback's visual weight.
            let tint = lastGroupColor.nsColor
            layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
            layer?.cornerRadius = 6
            layer?.borderColor  = tint.withAlphaComponent(0.40).cgColor
            layer?.borderWidth  = 1
        } else {
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
        }
    }
}
