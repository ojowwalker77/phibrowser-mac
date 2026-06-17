// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import AppKit

enum HeaderExtensionLayout {
    static let buttonSize: CGFloat = 24
    static let iconSize: CGFloat = 14
    static let itemSpacing: CGFloat = 2
}

/// Small badge pill overlaid on an extension icon, mirroring Chrome's action
/// badge. Colors come resolved from Chromium (see ExtensionManager.BadgeState).
struct ExtensionBadge: View {
    let state: ExtensionManager.BadgeState

    var body: some View {
        Text(state.text)
            .font(.system(size: 8, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(Color(nsColor: state.textColor))
            .padding(.horizontal, 2)
            .frame(minWidth: 11, minHeight: 11)
            .background(Capsule().fill(Color(nsColor: state.backgroundColor)))
            .fixedSize()
    }
}

/// Full-size, non-interactive SwiftUI overlay for embedding the badge on AppKit
/// surfaces via `NSHostingView`. Host it edge-pinned over the button/cell
/// (edges are flip-agnostic, unlike AppKit top/bottom constraints); inside, a
/// centered `iconSize` region anchors the badge to the icon's bottom-right via
/// SwiftUI's flip-correct `.bottomTrailing`. Self-observing, so the host updates
/// when the badge changes — no manual subscription needed.
struct BadgeCornerOverlay: View {
    @ObservedObject var manager: ExtensionManager
    let extensionId: String
    let iconSize: CGFloat

    var body: some View {
        Color.clear
            .overlay {
                Color.clear
                    .frame(width: iconSize, height: iconSize)
                    .extensionBadgeOverlay(manager.badges[extensionId])
            }
            .allowsHitTesting(false)
    }
}

/// Hosts a decorative badge overlay over an AppKit control without intercepting
/// its clicks. A plain `NSHostingView` can still swallow mouse events even when
/// its SwiftUI content is `.allowsHitTesting(false)` — which kills a SwiftUI
/// `Button`-backed control beneath it (e.g. the sidebar address-bar extension
/// icon, whose `HoverableButton` tap then never fires). Forcing `hitTest` to nil
/// passes every event through to the control below.
final class BadgeHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// Overlays the action badge straddling this icon's bottom-right corner
    /// (partial overlap, Chrome-style). Apply directly to the icon view so the
    /// badge anchors to the icon, not its (larger) container.
    func extensionBadgeOverlay(_ state: ExtensionManager.BadgeState?) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let state, !state.text.isEmpty {
                ExtensionBadge(state: state)
                    .offset(x: 4, y: 4)
                    .allowsHitTesting(false)
            }
        }
    }
}

@Observable
@MainActor
final class WebContentHeaderExtensionsModel {
    /// The full sorted pinned set.
    private(set) var pinnedExtensions: [Extension] = []
    /// Pinned extensions whose action is visible on the current tab — what the
    /// header actually lays out. Filtering here (not just per-button EmptyView)
    /// stops a hidden page action from consuming a width slot and truncating a
    /// genuinely visible extension off the header.
    private(set) var visiblePinnedExtensions: [Extension] = []

    private weak var browserState: BrowserState?
    private var cancellables = Set<AnyCancellable>()

    init(browserState: BrowserState?) {
        self.browserState = browserState
        bindExtensions()
        refreshExtensionsIfNeeded()
    }

    private func bindExtensions() {
        guard let manager = browserState?.extensionManager else { return }

        manager.$pinedExtensions
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] exts in
                let sorted = exts.sorted { lhs, rhs in
                    if lhs.pinnedIndex == rhs.pinnedIndex {
                        return lhs.name < rhs.name
                    }
                    return lhs.pinnedIndex < rhs.pinnedIndex
                }
                self?.pinnedExtensions = sorted
                self?.recomputeVisiblePinned()
            }
            .store(in: &cancellables)

        // Recompute the laid-out set when an extension's visibility flips (a page
        // action shown/hidden on the current tab). Gated on the hidden-id set so
        // a rapid badge-text tick (e.g. a blocked-count) does NOT recompute.
        manager.$badges
            .map { badges in Set(badges.compactMap { $0.value.visible ? nil : $0.key }) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeVisiblePinned()
            }
            .store(in: &cancellables)
    }

    private func recomputeVisiblePinned() {
        let badges = browserState?.extensionManager.badges
        visiblePinnedExtensions = pinnedExtensions.filter {
            badges?[$0.id]?.visible != false
        }
    }

    private func refreshExtensionsIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.browserState?.extensionManager.refreshExtensions()
        }
    }
}

struct CircularIconButton: View {
    let image: NSImage?
    let imageResource: ImageResource?
    let systemName: String?
    let accessibilityLabel: String
    let action: () -> Void
    let secondaryAction: (() -> Void)?

    @State private var isHovering = false

    init(
        image: NSImage? = nil,
        imageResource: ImageResource? = nil,
        systemName: String? = nil,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.image = image
        self.imageResource = imageResource
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovering ? .sidebarTabHoveredColorEmphasized : Color.clear)

                if let imageResource {
                    Image(imageResource)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: HeaderExtensionLayout.iconSize, height: HeaderExtensionLayout.iconSize)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: HeaderExtensionLayout.iconSize, height: HeaderExtensionLayout.iconSize)
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: HeaderExtensionLayout.iconSize, weight: .regular))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: HeaderExtensionLayout.buttonSize, height: HeaderExtensionLayout.buttonSize)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .overlay(
            SecondaryClickPassthrough(onSecondaryClick: secondaryAction)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

/// Red dot on the ⊞ overflow button when an *unpinned* extension has a
/// non-empty, visible badge on the current tab (so it isn't missed off-toolbar).
private struct OverflowBadgeDot: View {
    /// Product decision (2026-06): the dot is force-hidden — with several
    /// unpinned badge-setting extensions installed (Stylish, Tampermonkey,
    /// DuckDuckGo, …) it would be lit almost permanently and reads as noise.
    /// To bring the dot back, flip this to true; the detection logic below is
    /// intentionally kept working.
    private static let isEnabled = false

    @ObservedObject var manager: ExtensionManager

    var body: some View {
        let pinnedIds = Set(manager.pinedExtensions.map(\.id))
        let hasHiddenBadge = manager.badges.contains { id, state in
            !state.text.isEmpty && state.visible && !pinnedIds.contains(id)
        }
        if Self.isEnabled && hasHiddenBadge {
            Circle().fill(.red).frame(width: 6, height: 6)
        }
    }
}

struct HeaderExtensionMenuButton: View {
    let extensionManager: ExtensionManager?
    @Binding var isPopoverShown: Bool

    @State private var anchorView: NSView?

    var body: some View {
        CircularIconButton(
            imageResource: .extensionIcon,
            accessibilityLabel: NSLocalizedString("Extensions", comment: "Web content header - Extensions menu button")
        ) {
            isPopoverShown.toggle()
        }
        .overlay(alignment: .bottomTrailing) {
            if let manager = extensionManager {
                OverflowBadgeDot(manager: manager).offset(x: 2, y: 2)
            }
        }
        .background(
            AddressBarAnchorView { view in
                anchorView = view
            }
            .allowsHitTesting(false)
        )
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            if let manager = extensionManager {
                ExtensionList(
                    extensionManager: manager,
                    needSettings: false,
                    onRequestDismiss: { isPopoverShown = false },
                    triggerAnchorView: anchorView
                )
            }
        }
    }
}

struct HeaderExtensionContainer: View {
    let pinnedExtensions: [Extension]
    let extensionManager: ExtensionManager?
    let browserState: BrowserState?
    @Binding var isPopoverShown: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: HeaderExtensionLayout.itemSpacing) {
            ForEach(pinnedExtensions) { ext in
                if let manager = extensionManager {
                    PinnedExtensionButton(
                        ext: ext,
                        windowId: browserState?.windowId.int64Value ?? 0,
                        manager: manager
                    )
                }
            }
            HeaderExtensionMenuButton(
                extensionManager: extensionManager,
                isPopoverShown: $isPopoverShown
            )
        }
        .frame(height: HeaderTrailingLayout.rowHeight)
        .background(
            Capsule()
                .themedStroke(.border)
                .opacity(isHovering ? 1 : 0)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct PinnedExtensionButton: View {
    let ext: Extension
    let windowId: Int64
    @ObservedObject var manager: ExtensionManager

    @State private var anchorView: NSView?

    var body: some View {
        let badge = manager.badges[ext.id]
        // A hidden page action is not rendered at all (Phi spec §1).
        if badge?.visible == false {
            EmptyView()
        } else {
            // Dynamic action icon (setIcon / declarative) overrides the static
            // manifest icon; a grayed action (disabled + no page interaction)
            // comes back desaturated. Re-renders on any badges change via the
            // observed manager.
            let image = manager.iconImage(extensionId: ext.id, staticIcon: ext.icon)

            CircularIconButton(
                image: image,
                accessibilityLabel: ext.name,
                action: {
                    let point = anchorView.flatMap(ExtensionPopupAnchor.pointBelowView)
                        ?? ExtensionPopupAnchor.mouseFallback()
                    // A disabled action doesn't run; fall back to the context
                    // menu like Chrome (ExecuteUserAction). Read live state —
                    // the closure may outlive this render.
                    if manager.badges[ext.id]?.enabled == false {
                        ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
                            withId: ext.id,
                            pointInScreen: point,
                            windowId: windowId
                        )
                        return
                    }
                    ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
                        withId: ext.id,
                        pointInScreen: point,
                        windowId: windowId
                    )
                },
                secondaryAction: {
                    let point = anchorView.flatMap(ExtensionPopupAnchor.pointBelowView)
                        ?? ExtensionPopupAnchor.mouseFallback()
                    ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
                        withId: ext.id,
                        pointInScreen: point,
                        windowId: windowId
                    )
                }
            )
            // Anchor the badge to the centered icon (not the larger button) so
            // it straddles the icon's bottom-right corner.
            .overlay {
                Color.clear
                    .frame(width: HeaderExtensionLayout.iconSize,
                           height: HeaderExtensionLayout.iconSize)
                    .extensionBadgeOverlay(badge)
            }
            .background(
                AddressBarAnchorView { view in
                    anchorView = view
                }
                .allowsHitTesting(false)
            )
        }
    }
}
