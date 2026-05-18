// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import AppKit

/// View model for the sidebar's tab-group header row. Mirrors `WebContentGroupInfo`
/// (the data-layer source of truth for visuals) plus a derived tab count read
/// from `BrowserState.normalTabs.filter { $0.groupToken == token }`. Membership
/// is not stored on the group; the count is computed live and republished
/// whenever `normalTabs` changes.
@Observable
@MainActor
final class TabGroupHeaderViewModel {
    var color: GroupColor = .grey
    var displayTitle: String = ""
    var tabCount: Int = 0
    /// `true` when the pointer is over the header strip specifically
    /// (not the full group cell). Drives the close button's visibility
    /// — collapsed groups have header == cell so it's effectively
    /// cell-level; expanded groups scope it to the top `headerHeight`pt.
    /// Written by SwiftUI's `.onHover` on the header HStack; read by
    /// `TabGroupHeaderHostingView`'s hit-test guard so a click in the
    /// close zone is only counted when the button is visible.
    var isHeaderHovered: Bool = false
    /// Mirrors `WebContentGroupInfo.isCollapsed` so the inline chevron
    /// in `TabGroupHeaderView` can rotate without driving the state.
    var isCollapsed: Bool = false

    private var configuredToken: String?
    private var cancellables = Set<AnyCancellable>()

    func configure(with group: WebContentGroupInfo, in browserState: BrowserState) {
        configuredToken = group.token
        let initialCount = browserState.normalTabs.lazy
            .filter { $0.groupToken == group.token }.count
        color = group.color
        tabCount = initialCount
        displayTitle = group.displayTitle(memberCount: initialCount)
        isCollapsed = group.isCollapsed

        cancellables.removeAll()
        let expectedToken = group.token

        group.$isCollapsed
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                guard let self, self.configuredToken == expectedToken else { return }
                self.isCollapsed = newValue
            }
            .store(in: &cancellables)

        // Title changes can rewrite the resolved display title.
        group.$title
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak group] _ in
                guard let self, let group, self.configuredToken == expectedToken else { return }
                self.displayTitle = group.displayTitle(memberCount: self.tabCount)
            }
            .store(in: &cancellables)

        // Color flips both the bar tint and (for auto-named groups) the
        // localized color name embedded in displayTitle.
        group.$color
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak group] newColor in
                guard let self, let group, self.configuredToken == expectedToken else { return }
                self.color = newColor
                self.displayTitle = group.displayTitle(memberCount: self.tabCount)
            }
            .store(in: &cancellables)

        // Member count is derived from the tab list since `Tab.groupToken`
        // is the single source of truth for membership. Republishes on
        // every tab list change; `removeDuplicates()` filters out
        // unrelated reorders that don't affect this group's count.
        browserState.$normalTabs
            .map { tabs in tabs.lazy.filter { $0.groupToken == expectedToken }.count }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak group] newCount in
                guard let self, let group, self.configuredToken == expectedToken else { return }
                self.tabCount = newCount
                self.displayTitle = group.displayTitle(memberCount: newCount)
            }
            .store(in: &cancellables)
    }

    func cancelSubscriptions() {
        cancellables.removeAll()
    }
}

/// Compact header row for a tab group. Interaction is handled by
/// `TabGroupHeaderHostingView` so the title area can stay draggable.
struct TabGroupHeaderView: View {
    var viewModel: TabGroupHeaderViewModel
    @State private var isCloseButtonHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(viewModel.isCollapsed ? 0 : 90))
                .animation(.easeInOut(duration: 0.15), value: viewModel.isCollapsed)

            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: viewModel.color.nsColor))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1))
                    .frame(width: 10, height: 10)

                Text(viewModel.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            // Visual styling mirrors `UnifiedTabCloseButton`
            // (Sources/UserInterface/Common/Tabs/TabContentView.swift)
            // so grouped and ungrouped tab close affordances look
            // identical. Click dispatch keeps using the host view's
            // manual hit-test (`TabGroupHeaderHitTargetResolver`) so
            // the surrounding header strip can remain a whole-group
            // drag source.
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .themedFill(.hover)
                    .opacity(isCloseButtonHovered ? 1 : 0)

                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 24, height: 24)
            .opacity(viewModel.isHeaderHovered ? 1 : 0)
            .onHover { hovering in
                isCloseButtonHovered = hovering && viewModel.isHeaderHovered
            }
        }
//        .debugBorder()
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `contentShape` makes the empty horizontal space between the
        // chevron / title / close button hit-testable so `.onHover`
        // fires across the entire header strip, not just on the
        // individual visible subviews.
        .contentShape(Rectangle())
        .onHover { hovering in
            viewModel.isHeaderHovered = hovering
        }
    }
}

enum TabGroupHeaderHitTarget {
    case closeGroup
}

/// Resolves the close-button hit zone on the header. The rest of the
/// header strip (chevron, color dot, title, empty space) is treated as
/// a single "toggle / drag" surface by `TabGroupHeaderHostingView` —
/// click toggles collapse, drag starts a whole-group drag.
struct TabGroupHeaderHitTargetResolver {
    static let controlSize: CGFloat = 24
    static let horizontalInset: CGFloat = 6

    static func target(at point: CGPoint, in bounds: CGRect) -> TabGroupHeaderHitTarget? {
        let originY = bounds.midY - controlSize * 0.5
        let closeRect = CGRect(
            x: bounds.maxX - horizontalInset - controlSize,
            y: originY,
            width: controlSize,
            height: controlSize
        )
        return closeRect.contains(point) ? .closeGroup : nil
    }
}
