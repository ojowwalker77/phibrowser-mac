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
    /// True iff the user has set an explicit title. Drives count-badge
    /// visibility: when false, `displayTitle` already includes the count
    /// ("Blue · 3 tabs") so a separate badge would be redundant — same as
    /// upstream Chrome's tab-strip group chip.
    var hasUserSetTitle: Bool = false
    /// Mirrors `WebContentGroupInfo.isCollapsed` so the inline chevron
    /// in `TabGroupHeaderView` can rotate without driving the state
    /// itself. The cell owns the bridge round-trip via `onToggleCollapsed`.
    var isCollapsed: Bool = false

    /// Fires when the inline chevron is tapped. Cell wires this to its
    /// `TabGroupCellViewDelegate.tabGroupCellDidToggleCollapse(_:group:)`
    /// dispatch.
    @ObservationIgnored
    var onToggleCollapsed: (() -> Void)?

    private var configuredToken: String?
    private var cancellables = Set<AnyCancellable>()

    func configure(with group: WebContentGroupInfo, in browserState: BrowserState) {
        configuredToken = group.token
        let initialCount = browserState.normalTabs.lazy
            .filter { $0.groupToken == group.token }.count
        color = group.color
        tabCount = initialCount
        displayTitle = group.displayTitle(memberCount: initialCount)
        hasUserSetTitle = group.hasUserSetTitle
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

        // Title change rewrites both the display string and the badge
        // visibility (badge hides on auto-name).
        group.$title
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak group] newTitle in
                guard let self, let group, self.configuredToken == expectedToken else { return }
                self.hasUserSetTitle = !newTitle.isEmpty
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

/// Compact header row for a tab group: color bar + display title +
/// optional count badge + trailing inline chevron driving the
/// expand/collapse toggle.
struct TabGroupHeaderView: View {
    var viewModel: TabGroupHeaderViewModel

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(nsColor: viewModel.color.nsColor))
                .frame(width: 3, height: 16)

            Text(viewModel.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(nsColor: .labelColor))
                .lineLimit(1)
                .truncationMode(.tail)

            if viewModel.hasUserSetTitle {
                Text("\(viewModel.tabCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                    )
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(viewModel.isCollapsed ? 0 : 90))
                .animation(.easeInOut(duration: 0.15), value: viewModel.isCollapsed)
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
