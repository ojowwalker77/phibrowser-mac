// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// State machine for the trackpad swipe-to-switch-Space gesture, shared by
/// the sidebar (vertical layouts) and the tab strip bar (traditional
/// layout). The gesture's axis is latched on the first non-zero delta and
/// holds for the rest of the gesture (including momentum), so a swipe that
/// drifts diagonally doesn't alternate between scrolling and switching.
/// Horizontal-dominant gestures are consumed entirely; callers forward
/// `.passthrough` events to `super.scrollWheel`.
final class SpaceSwipeTracker {
    enum Outcome {
        /// Legacy wheel event or vertical-dominant gesture — scroll as usual.
        case passthrough
        /// Part of a horizontal gesture; swallow without acting.
        case consumed
        /// Horizontal travel crossed the threshold — fired once per gesture.
        /// The deltas follow `scrollingDeltaX` as-is, so the system
        /// scroll-direction setting applies: content-left means the next
        /// Space (+1), content-right the previous (-1).
        case trigger(step: Int)
    }

    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var accumulatedX: CGFloat = 0
    private var triggered = false
    private static let threshold: CGFloat = 50

    func handle(_ event: NSEvent) -> Outcome {
        // Legacy wheel events carry no gesture phases; never treat them as
        // swipes.
        guard event.phase != [] || event.momentumPhase != [] else { return .passthrough }

        if event.phase == .mayBegin || event.phase == .began {
            axis = .undecided
            accumulatedX = 0
            triggered = false
        }

        if axis == .undecided {
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if dx > dy {
                axis = .horizontal
            } else if dy > dx {
                axis = .vertical
            }
        }

        guard axis == .horizontal else { return .passthrough }

        accumulatedX += event.scrollingDeltaX
        if !triggered, abs(accumulatedX) >= Self.threshold {
            triggered = true
            return .trigger(step: accumulatedX < 0 ? 1 : -1)
        }
        return .consumed
    }
}

/// Compact active-Space header that sits between the pinned-tab strip and
/// the regular tab list. Shows the active Space's icon + name on the left
/// and an ellipsis affordance on the right that opens a popover listing
/// every Space (with its bound profile) plus a "+" row to create a new one.
///
/// Per-Space actions (rename / icon / theme / URL rules / delete) live on
/// each popover row's context menu — the picker is also the place to edit
/// existing Spaces, so the user never has to leave it once it's open.
struct SpacesStripView: View {
    @ObservedObject var manager: SpaceManager
    /// Per-window slot driving the active-Space highlight and the destination
    /// of activations. Each window's sidebar gets its own slot, so clicks here
    /// only affect this window.
    @ObservedObject var slot: SpaceWindowSlot
    /// Row height. The sidebar mounts a slimmer row than the horizontal
    /// toolbar; this also sizes the scrolling-label clip window.
    var rowHeight: CGFloat = SpacesStripView.height
    /// When false (horizontal tab strip), the switch is a compact icon+name
    /// chip with no trailing ellipsis — tapping the chip opens the picker.
    /// When true (sidebar), the label sits left with a trailing ellipsis
    /// affordance and a spacer between them.
    var showsEllipsisAffordance: Bool = true
    @ObservedObject private var profileManager: ProfileManager = .shared
    @Environment(\.phiAppearance) private var windowAppearance: Appearance

    @State private var isPickerOpen: Bool = false
    @State private var isIconPickerOpen: Bool = false

    /// Drag-reorder state for the sidebar icon strip. `stripOrderedIds` is the
    /// live arrangement shown while a pip is dragged across its siblings, and
    /// `stripDraggingId` marks the pip under the cursor. Mirrors the popover's
    /// picker (SpacePickerPopup) so the commit path through `manager.reorder`
    /// is identical.
    @State private var stripDraggingId: String?
    @State private var stripOrderedIds: [String] = []

    /// The pip currently under the cursor, driving its hover tooltip (Space name,
    /// bound profile, and keyboard shortcut). Only one pip is hovered at a time.
    @State private var hoveredSpaceId: String?

    /// The pip whose icon/emoji picker is open, presented from its right-click
    /// "Change Icon…" entry. Only one picker is open at a time.
    @State private var iconEditSpaceId: String?

    /// Owns the click-through floating panel that renders a pip's hover card.
    /// A transient `.popover` consumed the next click (its own dismissal), so the
    /// pip's switch never fired; this passthrough panel lets the click fall
    /// straight through to the pip. Mirrors TabStrip's drag-image panel — the
    /// codebase's existing `ignoresMouseEvents` floating-window pattern.
    @StateObject private var tooltipController = SpaceHoverTooltipController()

    /// The Space whose icon + name are currently shown. Lags `slot.activeSpaceId`
    /// by one animated step so the label can scroll the outgoing Space out and
    /// the incoming one in. `scrollEdge` is set just before the animated change
    /// so the motion direction matches the Space order (later Space → scroll up).
    @State private var displayedSpaceId: String?
    @State private var scrollEdge: Edge = .bottom

    /// Single-row height — matches the visual rhythm of pinned-tab rows above.
    static let height: CGFloat = 30
    /// Slimmer height used when the switch sits at the top of the sidebar.
    static let sidebarHeight: CGFloat = 24
    private static let horizontalPadding: CGFloat = 10
    /// Tighter horizontal padding for the lone horizontal-layout chip, so the
    /// single Space icon hugs its glyph instead of floating in a wide chip.
    /// `TabStripBarController.trafficLightInset` is tuned against this value to
    /// keep the icon centered between the traffic lights and the first tab.
    private static let compactChipHorizontalPadding: CGFloat = 2
    private static let iconSize: CGFloat = 14
    private static let iconHitSize: CGFloat = 22
    /// Uniform hit-target width of every item in the single-row strip — pips,
    /// the "…" overflow affordance, and the add button — and the gap between
    /// them. Drives the fit arithmetic in `visiblePipCount`.
    private static let stripItemWidth: CGFloat = 24
    private static let stripSpacing: CGFloat = 4

    /// Preset palette used for new-Space creation. Ordered so successive new
    /// Spaces are visually distinct without forcing the user into a color
    /// picker on creation.
    static let colorPalette: [(hex: String, name: String)] = [
        ("#3A6FF8", "Blue"),
        ("#E5484D", "Red"),
        ("#46A758", "Green"),
        ("#F76B15", "Orange"),
        ("#8E4EC6", "Purple"),
        ("#0091FF", "Cyan")
    ]

    var body: some View {
        // Height is set by the caller (SnapKit constraint in the sidebar,
        // SwiftUI frame in the horizontal toolbar) so the picker can adapt
        // to whichever row it's plugged into.
        Group {
            if showsEllipsisAffordance {
                iconStrip
            } else {
                compactChip
            }
        }
        .padding(.horizontal, showsEllipsisAffordance ? Self.horizontalPadding : Self.compactChipHorizontalPadding)
        .contentShape(Rectangle())
        .onChange(of: slot.iconPickerRequestToken) { _ in
            openActiveIconPicker()
        }
    }

    /// Opens the icon/emoji picker for the active Space anchored below its icon —
    /// the active pip in the sidebar, or the chip's icon in the tab strip — in
    /// response to the tab-area menu's "Change Icon…" request.
    private func openActiveIconPicker() {
        guard let activeId = slot.activeSpaceId else { return }
        if showsEllipsisAffordance {
            iconEditSpaceId = activeId
        } else {
            isPickerOpen = false
            isIconPickerOpen = true
        }
    }

    /// Compact affordance for the horizontal tab strip: just the active Space's
    /// icon, acting as a menu button. Hovering or left-clicking it drops the
    /// Space-switcher menu (one item per Space, plus "New Space"); right-clicking
    /// it shows the tab strip's context menu (the active-Space controls). Both are
    /// AppKit NSMenus attached to the chip's hosting view in TabStripBarController
    /// — the switcher on hover/left-click, the context menu on right-click — so
    /// the chip intentionally has no SwiftUI `.contextMenu` or popover of its own.
    private var compactChip: some View {
        activeLabel
        .help(NSLocalizedString("Spaces", comment: "Tooltip for the Spaces picker affordance"))
    }

    /// The active Space's icon, shown in the horizontal tab strip.
    @ViewBuilder
    private var activeLabel: some View {
        scrollingLabel
        .contentShape(Rectangle())
    }

    /// The active Space's icon, scrolling vertically when the active Space
    /// changes: the outgoing Space's icon slides off one edge while the incoming
    /// one slides in from the other (later Space → scroll up, earlier → scroll
    /// down), clipped to the row height so it reads as a ticker.
    private var scrollingLabel: some View {
        // The clip + fixed frame live on the STABLE container (the ZStack), not
        // on the transitioning label — otherwise the clip travels out with the
        // outgoing icon and the old icon lingers above/below the row.
        ZStack(alignment: .leading) {
            label(for: spaceModel(displayedSpaceId))
                .id(displayedSpaceId ?? "none")
                .transition(.asymmetric(
                    insertion: .move(edge: scrollEdge).combined(with: .opacity),
                    removal: .move(edge: scrollEdge == .bottom ? .top : .bottom).combined(with: .opacity)
                ))
        }
        .frame(height: rowHeight, alignment: .leading)
        .clipped()
        .onAppear {
            if displayedSpaceId == nil { displayedSpaceId = slot.activeSpaceId }
        }
        .onChange(of: slot.activeSpaceId) { newId in
            let oldIndex = manager.spaces.firstIndex { $0.spaceId == displayedSpaceId }
            let newIndex = manager.spaces.firstIndex { $0.spaceId == newId }
            scrollEdge = (newIndex ?? 0) >= (oldIndex ?? 0) ? .bottom : .top
            // Match the band push-in exactly (same curve + duration) so the
            // icon scroll and the slide move together.
            withAnimation(.easeInOut(duration: PhiPreferences.GeneralSettings.loadSwitchSpaceAnimationDuration())) {
                displayedSpaceId = newId
            }
        }
    }

    private func spaceModel(_ id: String?) -> SpaceModel? {
        guard let id else { return nil }
        return manager.spaces.first { $0.spaceId == id }
    }

    private func label(for space: SpaceModel?) -> some View {
        activeIcon(for: space)
    }

    /// The active Space's icon. Clicking the chip opens the Space-switcher menu
    /// (popped by the hosting view), not the icon picker — but this view still
    /// hosts the icon-picker popover that the menu's / tab-area "Change Icon…"
    /// entry anchors to.
    private func activeIcon(for space: SpaceModel?) -> some View {
        SpaceIconView(
            storedValue: space?.iconName,
            size: Self.iconSize,
            symbolWeight: .semibold,
            tint: space.map(iconColor(for:)) ?? Color.secondary
        )
        .frame(width: Self.iconHitSize, height: Self.iconHitSize)
        .contentShape(Rectangle())
        .popover(isPresented: $isIconPickerOpen, arrowEdge: .bottom) {
            iconPicker(for: space)
        }
    }

    @ViewBuilder
    private func iconPicker(for space: SpaceModel?) -> some View {
        if let space {
            IconPicker(
                selected: IconPickerSelection.fromStorageValue(space.iconName),
                showsGroups: true,
                onSelect: { selection in
                    manager.changeIcon(spaceId: space.spaceId, iconName: selection.storageValue)
                    isIconPickerOpen = false
                }
            )
        }
    }

    /// Sidebar chooser: one tappable icon per Space (the active one carries its
    /// theme tint, the rest read muted) followed by a trailing "+" that creates
    /// a new Space. A large number of Spaces can overflow the row; the
    /// common handful fit within the sidebar width.
    private var iconStrip: some View {
        // Single row that never wraps: show as many leading pips as fit, then a
        // trailing "…" affordance once any are hidden (it opens the picker with
        // the full list). The add button stays pinned to the right via a Spacer.
        GeometryReader { geo in
            let visibleCount = visiblePipCount(availableWidth: geo.size.width)
            let hasOverflow = visibleCount < stripOrderedSpaces.count
            HStack(spacing: Self.stripSpacing) {
                ForEach(stripOrderedSpaces.prefix(visibleCount), id: \.spaceId) { space in
                    spacePip(for: space)
                        .opacity(stripDraggingId == space.spaceId ? 0.5 : 1)
                        .onDrag {
                            stripDraggingId = space.spaceId
                            return NSItemProvider(object: space.spaceId as NSString)
                        }
                        .onDrop(of: [.text], delegate: SpaceRowDropDelegate(
                            targetSpaceId: space.spaceId,
                            draggingSpaceId: $stripDraggingId,
                            orderedIds: $stripOrderedIds,
                            commit: { manager.reorder(spaceIds: $0) }
                        ))
                }
                if hasOverflow {
                    moreButton(excludedSpaceIds: Set(stripOrderedSpaces.prefix(visibleCount).map(\.spaceId)))
                }
                Spacer(minLength: 4)
                addButton
            }
            .frame(width: geo.size.width, height: rowHeight, alignment: .leading)
        }
        .frame(height: rowHeight)
        // Reset a drag that ends off every pip (Spacer / add button / "…" /
        // padding) so the lifted pip doesn't stay dimmed and `stripOrderedIds`
        // re-sync doesn't stay frozen until the next drag. See the delegate doc.
        .onDrop(of: [.text], delegate: SpaceListResetDropDelegate(
            draggingSpaceId: $stripDraggingId,
            orderedIds: $stripOrderedIds,
            commit: { manager.reorder(spaceIds: $0) }
        ))
        .onAppear { stripOrderedIds = manager.spaces.map(\.spaceId) }
        .onChange(of: manager.spaces.map(\.spaceId)) { ids in
            // Leave an in-flight drag's local rearrangement alone; the drop's
            // commit writes through and re-syncs on the next pass.
            guard stripDraggingId == nil else { return }
            stripOrderedIds = ids
        }
    }

    /// How many leading pips fit on the single row, reserving room for the
    /// trailing add button and — when any pips are hidden — a "…" affordance.
    /// All strip items share a uniform width, so the count is pure arithmetic.
    private func visiblePipCount(availableWidth: CGFloat) -> Int {
        let total = stripOrderedSpaces.count
        guard total > 0 else { return 0 }
        let item = Self.stripItemWidth
        let spacing = Self.stripSpacing
        func width(_ items: Int) -> CGFloat {
            items <= 0 ? 0 : CGFloat(items) * item + CGFloat(items - 1) * spacing
        }
        // Room left of the add button (which keeps a small gap before it).
        let budget = availableWidth - item - spacing
        // Everything fits with no "…"?
        if width(total) <= budget { return total }
        // Overflowing: reserve a "…" slot and fit as many leading pips as possible.
        var count = total - 1
        while count > 0, width(count + 1) > budget { count -= 1 }
        return max(count, 0)
    }

    /// Pips in drag order: the local `stripOrderedIds` snapshot (rearranged live
    /// while a drag hovers across pips), with any Space the snapshot doesn't know
    /// yet appended in the manager's order. Mirrors SpacePickerPopup.orderedSpaces.
    private var stripOrderedSpaces: [SpaceModel] {
        guard !stripOrderedIds.isEmpty else { return manager.spaces }
        let byId = Dictionary(uniqueKeysWithValues: manager.spaces.map { ($0.spaceId, $0) })
        var result = stripOrderedIds.compactMap { byId[$0] }
        let known = Set(stripOrderedIds)
        result.append(contentsOf: manager.spaces.filter { !known.contains($0.spaceId) })
        return result
    }

    /// A single Space's icon, rendered through `SpaceIconView` so phi-icons,
    /// emoji, and legacy SF Symbols all display correctly. Tapping switches this
    /// window to that Space; the active pip stays at full strength while the rest
    /// dim, so the difference is only brightness — never a different icon style.
    private func spacePip(for space: SpaceModel) -> some View {
        // Normally the highlight follows `activeSpaceId` (matching the Spaces
        // menu). During a vertical push-in the slot pins the strip to the
        // leaving Space (`pinnedStripSpaceId`) so the pip doesn't jump to the
        // target while the leaving Space's content is still on screen — the
        // strip lives in the leaving window's header, which stays visible for
        // the whole animation. The pin is cleared when the swap settles, so the
        // fallback keeps steady state correct.
        let highlightedSpaceId = slot.pinnedStripSpaceId ?? slot.activeSpaceId
        let isActive = space.spaceId == highlightedSpaceId
        return Button {
            slot.activate(spaceId: space.spaceId)
        } label: {
            SpaceIconView(
                storedValue: space.iconName,
                size: Self.iconSize,
                symbolWeight: .semibold,
                tint: Color.primary
            )
            .opacity(isActive ? 1 : 0.4)
            .frame(width: 24, height: rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.primary.opacity(0.1) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(space.name)
        .onHover { hovering in
            if hovering {
                hoveredSpaceId = space.spaceId
            } else if hoveredSpaceId == space.spaceId {
                hoveredSpaceId = nil
            }
        }
        .background(
            SpaceTooltipAnchor(
                isPresented: isHoverCardPresented(for: space),
                spaceId: space.spaceId,
                card: AnyView(hoverCard(for: space)),
                controller: tooltipController
            )
        )
        .popover(isPresented: iconEditBinding(for: space), arrowEdge: .bottom) {
            IconPicker(
                selected: IconPickerSelection.fromStorageValue(space.iconName),
                showsGroups: true,
                onSelect: { selection in
                    manager.changeIcon(spaceId: space.spaceId, iconName: selection.storageValue)
                    iconEditSpaceId = nil
                }
            )
        }
    }

    /// A pip's hover card shows while it (and only it) is hovered, and never
    /// during a reorder drag or while its icon picker is open so the card doesn't
    /// trail the cursor or fight the picker. `.onHover` drives `hoveredSpaceId`.
    private func isHoverCardPresented(for space: SpaceModel) -> Bool {
        hoveredSpaceId == space.spaceId && stripDraggingId == nil && iconEditSpaceId == nil
    }

    /// Presents the icon/emoji picker anchored to a pip when its right-click
    /// "Change Icon…" entry has targeted that Space.
    private func iconEditBinding(for space: SpaceModel) -> Binding<Bool> {
        Binding(
            get: { iconEditSpaceId == space.spaceId },
            set: { presented in
                if presented {
                    iconEditSpaceId = space.spaceId
                } else if iconEditSpaceId == space.spaceId {
                    iconEditSpaceId = nil
                }
            }
        )
    }

    /// Builds a pip's hover card from its bound profile, theme tint, and switch
    /// shortcut. Rendered in a passthrough floating panel (see
    /// `SpaceHoverTooltipController`) so it can't swallow the click that switches
    /// Spaces. The shortcut is empty for Spaces past the ninth, which have no
    /// ⌃-number binding.
    private func hoverCard(for space: SpaceModel) -> SpaceHoverCard {
        SpaceHoverCard(
            profileName: profileDisplayName(for: space.profileId),
            iconStoredValue: space.iconName,
            spaceName: space.name,
            iconColor: iconColor(for: space),
            shortcutTokens: spaceShortcut(for: space).map(keycapTokens) ?? []
        )
    }

    /// The effective (remap-aware) switch shortcut for a Space, resolved from its
    /// position in the manager's order — mirroring how the Spaces menu binds
    /// ⌃1…⌃9. Nil past the ninth Space or if the binding was cleared.
    private func spaceShortcut(for space: SpaceModel) -> ShortcutsKey? {
        guard let index = manager.spaces.firstIndex(where: { $0.spaceId == space.spaceId }),
              let command = CommandWrapper.spaceSelectionCommand(at: index) else { return nil }
        return Shortcuts.key(for: command)
    }

    /// Splits a shortcut into keycap tokens — one per modifier, then the key —
    /// so the tooltip can render them as separate badges (e.g. ⌃ and 6).
    private func keycapTokens(_ key: ShortcutsKey) -> [String] {
        var tokens: [String] = []
        let modifiers = key.modifiers
        if modifiers.contains(.command) { tokens.append("⌘") }
        if modifiers.contains(.option) { tokens.append("⌥") }
        if modifiers.contains(.shift) { tokens.append("⇧") }
        if modifiers.contains(.control) { tokens.append("⌃") }
        tokens.append(key.characters.uppercased())
        return tokens
    }

    /// Trailing affordance that opens the create-Space flow, seeding the new
    /// Space with the active Space's profile so it lands in the same context.
    private var addButton: some View {
        Button {
            CreateSpacePanel.requestCreation(initialProfileId: activeSpace?.profileId)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Self.iconSize, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 24, height: rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("New Space", comment: "Tooltip for the add-Space button in the sidebar Spaces strip"))
    }

    /// Overflow affordance shown when the row can't fit every Space. Drops a
    /// native menu listing only the Spaces that didn't fit (`excludedSpaceIds` are
    /// the pips already on screen) and no "New Space" row — creation stays on the
    /// strip's own "+" button. Same switcher menu the horizontal chip uses, just
    /// filtered via `AppController.populateSpaceSwitcherMenu`.
    private func moreButton(excludedSpaceIds: Set<String>) -> some View {
        Button {
            isIconPickerOpen = false
            isPickerOpen = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Self.iconSize, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: Self.stripItemWidth, height: rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("More Spaces", comment: "Tooltip for the overflow button that opens the full Spaces list"))
        .background(SpaceSwitcherMenuAnchor(isPresented: $isPickerOpen) { menu in
            AppController.shared?.populateSpaceSwitcherMenu(
                menu,
                excludedSpaceIds: excludedSpaceIds,
                includeNewSpace: false
            )
        })
    }

    /// The Space-switcher popover content. The horizontal chip lists every Space
    /// with a "New Space" row; the sidebar's "…" overflow popover passes the
    /// already-shown pip ids to `excludedSpaceIds` and `showsCreate: false`, so it
    /// only surfaces the Spaces that didn't fit and leaves creation to the strip's
    /// own "+" button.
    @ViewBuilder
    private func pickerPopup(excludedSpaceIds: Set<String> = [], showsCreate: Bool = true) -> some View {
        SpacePickerPopup(
            manager: manager,
            slot: slot,
            profileManager: profileManager,
            windowAppearance: windowAppearance,
            onActivate: { spaceId in
                slot.activate(spaceId: spaceId)
                isPickerOpen = false
            },
            onRename: { space in
                isPickerOpen = false
                promptRename(for: space)
            },
            onChangeIcon: { manager.changeIcon(spaceId: $0, iconName: $1) },
            onSetTheme: { manager.setTheme(forSpaceId: $0, themeId: $1) },
            currentThemeId: { manager.themeId(forSpaceId: $0) },
            onDelete: { space in
                isPickerOpen = false
                confirmDelete(space)
            },
            onCreate: {
                isPickerOpen = false
                CreateSpacePanel.requestCreation(initialProfileId: activeSpace?.profileId)
            },
            excludedSpaceIds: excludedSpaceIds,
            showsCreate: showsCreate
        )
    }

    private var activeSpace: SpaceModel? {
        if let id = slot.activeSpaceId {
            return manager.spaces.first { $0.spaceId == id }
        }
        return nil
    }

    /// Resolves a Space's bound profile to a user-visible name, falling back to
    /// the raw profileId if ProfileManager hasn't refreshed yet.
    private func profileDisplayName(for profileId: String) -> String {
        profileManager.profile(for: profileId)?.displayName ?? profileId
    }

    /// Each Space's accent comes from its pinned theme (or the global theme
    /// when no override is set), so the active-Space icon previews what the
    /// window currently looks like.
    fileprivate func iconColor(for space: SpaceModel) -> Color {
        let theme: Theme
        if let pinnedId = manager.themeId(forSpaceId: space.spaceId),
           let pinned = ThemeManager.shared.registeredThemes[pinnedId] {
            theme = pinned
        } else {
            theme = ThemeManager.shared.currentTheme
        }
        return Color(nsColor: theme.color(for: .textPrimary, appearance: windowAppearance))
    }

    private func promptRename(for space: SpaceModel) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Rename Space", comment: "Title of the rename-Space dialog")
        alert.informativeText = NSLocalizedString("Enter a new name for this Space.", comment: "Body of the rename-Space dialog")
        alert.addButton(withTitle: NSLocalizedString("Rename", comment: "Rename button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = space.name
        textField.placeholderString = space.name
        alert.accessoryView = textField
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
            textField.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        manager.renameSpace(spaceId: space.spaceId, to: trimmed)
    }

    private func confirmDelete(_ space: SpaceModel) {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete \u{201C}%@\u{201D}?", comment: "Title of the delete-Space confirmation"),
            space.name
        )
        alert.informativeText = NSLocalizedString(
            "Pinned tabs and bookmarks belonging to this Space will also be removed. This action cannot be undone.",
            comment: "Body of the delete-Space confirmation"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.deleteSpace(spaceId: space.spaceId)
    }
}

/// Popover content shown by the ellipsis button. Lists every Space with its
/// bound profile label, plus a footer row for creating a new one. Each row
/// is clickable to activate and right-clickable to edit / delete.
private struct SpacePickerPopup: View {
    @ObservedObject var manager: SpaceManager
    @ObservedObject var slot: SpaceWindowSlot
    @ObservedObject var profileManager: ProfileManager
    let windowAppearance: Appearance
    let onActivate: (String) -> Void
    let onRename: (SpaceModel) -> Void
    let onChangeIcon: (String, String) -> Void
    let onSetTheme: (String, String?) -> Void
    let currentThemeId: (String) -> String?
    let onDelete: (SpaceModel) -> Void
    let onCreate: () -> Void
    /// Spaces already shown as pips in the strip, hidden from this list so the
    /// overflow popover only surfaces the Spaces that didn't fit. Empty for the
    /// horizontal chip, which lists every Space.
    var excludedSpaceIds: Set<String> = []
    /// Whether to show the trailing "New Space" row. Off for the sidebar overflow
    /// popover, which sits next to the strip's own "+" button.
    var showsCreate: Bool = true

    private static let popoverWidth: CGFloat = 240

    @State private var draggingSpaceId: String?
    @State private var orderedIds: [String] = []
    @State private var isCreateHovering: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(orderedSpaces, id: \.spaceId) { space in
                        SpacePickerRow(
                            space: space,
                            isActive: space.spaceId == slot.activeSpaceId,
                            isDeletable: space.spaceId != LocalStore.defaultSpaceId,
                            tint: iconColor(for: space),
                            profileName: profileDisplayName(for: space.profileId),
                            onActivate: { onActivate(space.spaceId) },
                            onRename: { onRename(space) },
                            onChangeIcon: { onChangeIcon(space.spaceId, $0) },
                            onSetTheme: { onSetTheme(space.spaceId, $0) },
                            currentThemeId: { currentThemeId(space.spaceId) },
                            onDelete: { onDelete(space) }
                        )
                        .opacity(draggingSpaceId == space.spaceId ? 0.5 : 1)
                        .onDrag {
                            draggingSpaceId = space.spaceId
                            return NSItemProvider(object: space.spaceId as NSString)
                        }
                        .onDrop(of: [.text], delegate: SpaceRowDropDelegate(
                            targetSpaceId: space.spaceId,
                            draggingSpaceId: $draggingSpaceId,
                            orderedIds: $orderedIds,
                            commit: { manager.reorder(spaceIds: $0) }
                        ))
                    }
                }
                .padding(.vertical, 6)
            }

            if showsCreate {
                Divider()

                Button(action: onCreate) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 16)
                        Text(NSLocalizedString("New Space", comment: "Spaces picker - create a new Space"))
                            .font(.system(size: 13))
                        Spacer(minLength: 8)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isCreateHovering ? Color.primary.opacity(0.08) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isCreateHovering = $0 }
            }
        }
        .frame(width: Self.popoverWidth)
        .frame(maxHeight: 320)
        // Reset a drag that ends off every row (the create row / list padding)
        // so the lifted row doesn't stay dimmed and `orderedIds` re-sync doesn't
        // stay frozen until the next drag. See the delegate doc.
        .onDrop(of: [.text], delegate: SpaceListResetDropDelegate(
            draggingSpaceId: $draggingSpaceId,
            orderedIds: $orderedIds,
            commit: { manager.reorder(spaceIds: $0) }
        ))
        .onAppear { orderedIds = manager.spaces.map(\.spaceId) }
        .onChange(of: manager.spaces.map(\.spaceId)) { ids in
            // Don't fight an in-flight drag's local rearrangement; the
            // commit on drop writes through and re-syncs on the next pass.
            guard draggingSpaceId == nil else { return }
            orderedIds = ids
        }
    }

    /// Rows in drag order: the local `orderedIds` snapshot (rearranged live
    /// while a drag hovers across rows), with any Space the snapshot doesn't
    /// know yet appended in strip order.
    private var orderedSpaces: [SpaceModel] {
        let ordered: [SpaceModel]
        if orderedIds.isEmpty {
            ordered = manager.spaces
        } else {
            let byId = Dictionary(uniqueKeysWithValues: manager.spaces.map { ($0.spaceId, $0) })
            var result = orderedIds.compactMap { byId[$0] }
            let known = Set(orderedIds)
            result.append(contentsOf: manager.spaces.filter { !known.contains($0.spaceId) })
            ordered = result
        }
        guard !excludedSpaceIds.isEmpty else { return ordered }
        return ordered.filter { !excludedSpaceIds.contains($0.spaceId) }
    }

    private func iconColor(for space: SpaceModel) -> Color {
        let theme: Theme
        if let pinnedId = manager.themeId(forSpaceId: space.spaceId),
           let pinned = ThemeManager.shared.registeredThemes[pinnedId] {
            theme = pinned
        } else {
            theme = ThemeManager.shared.currentTheme
        }
        return Color(nsColor: theme.color(for: .textPrimary, appearance: windowAppearance))
    }

    /// Falls back to the raw profileId so the row still shows *something*
    /// useful if ProfileManager hasn't refreshed yet (e.g. very early after
    /// bridge bring-up).
    private func profileDisplayName(for profileId: String) -> String {
        if let p = ProfileManager.shared.profile(for: profileId) {
            return p.displayName
        }
        return profileId
    }
}

/// Reorders Space rows live while a row drag hovers over siblings and commits
/// the arrangement on drop. Movement happens in the view's local `orderedIds`
/// (not the persisted list), so SwiftData is written once — when the drop lands
/// — rather than on every row crossing. Shared by the sidebar Space picker and
/// the Spaces settings pane.
struct SpaceRowDropDelegate: DropDelegate {
    let targetSpaceId: String
    @Binding var draggingSpaceId: String?
    @Binding var orderedIds: [String]
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingSpaceId,
              dragging != targetSpaceId,
              let from = orderedIds.firstIndex(of: dragging),
              let to = orderedIds.firstIndex(of: targetSpaceId) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            orderedIds.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingSpaceId = nil
        commit(orderedIds)
        return true
    }
}

/// Catch-all reset for a Space drag that ends off every row. The per-row
/// `SpaceRowDropDelegate`s own reordering and take precedence within their
/// bounds; this fallback, attached to the enclosing container, catches a drop
/// that lands on the surrounding chrome (the strip's Spacer / add button / "…"
/// affordance / padding, or the picker's create row and list padding). Without
/// it `draggingSpaceId` would never reset there, leaving the lifted row dimmed
/// and freezing the local `orderedIds` re-sync until the next drag. It does no
/// reordering of its own — it just clears the drag and commits the order the row
/// delegates already arranged. (A hard Esc-cancel or a drop fully outside the
/// container still self-heals on the next drag's `onDrag`, which has no SwiftUI
/// cancel hook.) Shared by the sidebar strip, the picker popover, and the
/// Spaces settings list.
struct SpaceListResetDropDelegate: DropDelegate {
    @Binding var draggingSpaceId: String?
    @Binding var orderedIds: [String]
    let commit: ([String]) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingSpaceId = nil
        commit(orderedIds)
        return true
    }
}

/// Drops the native Space-switcher menu anchored to a SwiftUI button when
/// `isPresented` flips true, then resets it. Lets the sidebar's "…" overflow
/// affordance show the same AppKit menu as the horizontal active-Space chip
/// (built by `AppController.populateSpaceSwitcherMenu`) instead of a SwiftUI
/// popover, so both layouts share one switcher UI.
private struct SpaceSwitcherMenuAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// Fills the menu just before it pops, so each caller chooses what it lists.
    let populate: (NSMenu) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented, !context.coordinator.isShowing else { return }
        context.coordinator.isShowing = true
        // Pop on the next runloop so the menu drops after this view update and
        // mutating `isPresented` happens outside it. `isShowing` guards against a
        // second update re-scheduling while the (modal) menu is open.
        DispatchQueue.main.async {
            defer {
                context.coordinator.isShowing = false
                isPresented = false
            }
            let menu = NSMenu()
            populate(menu)
            guard menu.numberOfItems > 0 else { return }
            let bottomLeading = NSPoint(
                x: nsView.bounds.minX,
                y: nsView.isFlipped ? nsView.bounds.maxY : nsView.bounds.minY
            )
            menu.popUp(positioning: nil, at: bottomLeading, in: nsView)
        }
    }

    final class Coordinator {
        var isShowing = false
    }
}

private struct SpacePickerRow: View {
    let space: SpaceModel
    let isActive: Bool
    let isDeletable: Bool
    let tint: Color
    let profileName: String
    let onActivate: () -> Void
    let onRename: () -> Void
    let onChangeIcon: (String) -> Void
    let onSetTheme: (String?) -> Void
    let currentThemeId: () -> String?
    let onDelete: () -> Void

    @State private var isHovering: Bool = false
    @State private var showsIconPicker: Bool = false

    /// Drives the Change-Theme picker: nil = Follow Global, else a pinned id.
    private var themeSelection: Binding<String?> {
        Binding(
            get: { currentThemeId() },
            set: { onSetTheme($0) }
        )
    }

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                SpaceIconView(
                    storedValue: space.iconName,
                    size: 13,
                    symbolWeight: .semibold,
                    tint: isActive ? Color.white : tint
                )
                .frame(width: 16)
                Text(space.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? Color.white : Color.primary)
                Spacer(minLength: 8)
                Text(profileName)
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: $showsIconPicker, arrowEdge: .trailing) {
            IconPicker(
                selected: IconPickerSelection.fromStorageValue(space.iconName),
                showsGroups: true,
                onSelect: { selection in
                    showsIconPicker = false
                    onChangeIcon(selection.storageValue)
                }
            )
        }
        .contextMenu {
            Button(NSLocalizedString("Rename\u{2026}", comment: "")) { onRename() }
            Button(NSLocalizedString("Change Icon\u{2026}", comment: "Opens the icon/emoji picker for a Space")) {
                showsIconPicker = true
            }
            Menu(NSLocalizedString("Change Theme", comment: "")) {
                Picker(NSLocalizedString("Change Theme", comment: ""), selection: themeSelection) {
                    Label {
                        Text(NSLocalizedString("Follow Global", comment: "Theme menu: clear per-Space override"))
                    } icon: {
                        Image(nsImage: .themeColorSwatch(for: ThemeManager.shared.currentTheme))
                            .renderingMode(.original)
                    }
                    .tag(String?.none)

                    Divider()

                    ForEach(ThemeManager.shared.orderedThemes, id: \.id) { theme in
                        Label {
                            Text(theme.name)
                        } icon: {
                            Image(nsImage: .themeColorSwatch(for: theme))
                                .renderingMode(.original)
                        }
                        .tag(String?(theme.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if isDeletable {
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Text(NSLocalizedString("Delete", comment: "Destructive menu item"))
                }
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
                .padding(.horizontal, 6)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .padding(.horizontal, 6)
        } else {
            Color.clear
        }
    }
}

struct SpaceIconView: View {
    let storedValue: String?
    let size: CGFloat
    let symbolWeight: Font.Weight
    let tint: Color

    private var storedIconValue: String {
        guard let storedValue, !storedValue.isEmpty else { return "rectangle.stack" }
        return storedValue
    }

    var body: some View {
        if let selection = IconPickerSelection.fromStorageValue(storedIconValue) {
            switch selection {
            case .phiIcon:
                IconPickerSelectionView(selection: selection, size: size)
            case .emoji(_, let text):
                Text(text)
                    .font(.system(size: emojiFontSize))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: emojiFrameSize.width, height: emojiFrameSize.height)
            }
        } else if let symbol = systemSymbolName(for: storedIconValue) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: symbolWeight))
                .foregroundStyle(tint)
        } else {
            Image(systemName: "rectangle.stack")
                .font(.system(size: size, weight: symbolWeight))
                .foregroundStyle(tint)
        }
    }

    private var emojiFontSize: CGFloat {
        size + 1
    }

    private var emojiFrameSize: CGSize {
        CGSize(width: size + 4, height: size + 8)
    }

    /// A menu-ready icon for a Space's stored icon value, for use as an
    /// `NSMenuItem.image`. SF Symbols — including the empty-icon and legacy
    /// fallback — stay template images that invert with menu selection; phi-icons
    /// and emoji, which `NSImage(systemSymbolName:)` can't resolve, are rasterized
    /// from this view so they show in menus too. Call on the main thread (menu
    /// builds are synchronous on it); `ImageRenderer` is main-actor-bound.
    @MainActor
    static func menuImage(for storedValue: String, size: CGFloat = 16) -> NSImage? {
        let stored = storedValue.isEmpty ? "rectangle.stack" : storedValue
        if let symbolImage = NSImage(systemSymbolName: stored, accessibilityDescription: nil) {
            return symbolImage
        }
        let icon = SpaceIconView(
            storedValue: stored,
            size: size,
            symbolWeight: .semibold,
            tint: Color(nsColor: .labelColor)
        )
        .frame(width: size + 2, height: size + 2)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

/// SpaceModel.iconName may be either an IconPicker storage value or the legacy
/// SF Symbol id (e.g. "rectangle.stack"). Legacy symbols are resolved at view
/// time so old rows keep rendering without a data migration.
private func systemSymbolName(for stored: String) -> String? {
    stored.isEmpty ? nil : stored
}

/// A pip's hover card: the Space (icon + name) as a tinted pill on the left, the
/// bound profile name in the middle, and its switch shortcut as keycaps on the
/// right.
/// Self-contained (plain data in) so it can be hosted in a standalone panel by
/// `SpaceHoverTooltipController` instead of a transient `.popover` — the popover
/// swallowed the next click (its own dismissal), so the pip's switch never ran.
struct SpaceHoverCard: View {
    let profileName: String
    let iconStoredValue: String?
    let spaceName: String
    let iconColor: Color
    /// Per-keycap tokens (modifiers then key), or empty for Spaces without a
    /// ⌃-number binding.
    let shortcutTokens: [String]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                SpaceIconView(
                    storedValue: iconStoredValue,
                    size: 11,
                    symbolWeight: .semibold,
                    tint: iconColor
                )
                Text(spaceName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(iconColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(iconColor.opacity(0.15)))

            separatorDot

            Text(profileName)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)

            if !shortcutTokens.isEmpty {
                separatorDot

                HStack(spacing: 3) {
                    ForEach(Array(shortcutTokens.enumerated()), id: \.offset) { _, token in
                        keycap(token)
                    }
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // The panel hosting this card is borderless and clear, so the card draws
        // its own popover-like chrome (the popover used to provide it).
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    /// A subtle middle-dot divider between the card's sections.
    private var separatorDot: some View {
        Text("\u{00B7}")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.secondary.opacity(0.45))
    }

    /// A single keycap badge (one modifier symbol or the character).
    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
    }
}

/// Hosts a pip's hover card in a click-through floating `NSPanel`
/// (`ignoresMouseEvents`) anchored just above the pip. Because it is a separate,
/// non-interactive window there is no transient-popover dismiss monitor to
/// consume the next click, so a click on the pip falls straight through to its
/// Button and switches the Space. Mirrors TabStrip's drag-image panel.
final class SpaceHoverTooltipController: ObservableObject {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    /// The spaceId currently shown, so a stale pip's `dismiss` can't tear down a
    /// card another pip just presented (update order between pips isn't defined).
    private var ownerId: String?

    deinit { panel?.orderOut(nil) }

    /// Shows `card` for `spaceId`, centered above `anchorScreenRect`. Idempotent:
    /// re-presenting the same pip just repositions and refreshes the content.
    func present(spaceId: String, card: AnyView, anchorScreenRect: CGRect, screen: NSScreen?) {
        let panel = ensurePanel()
        ownerId = spaceId
        guard let hostingView else { return }
        hostingView.rootView = card
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize

        let gap: CGFloat = 6
        var origin = CGPoint(
            x: anchorScreenRect.midX - size.width / 2,
            y: anchorScreenRect.maxY + gap            // screen coords: +y is up → above the pip
        )
        if let visible = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            // Flip below the pip if showing above would clip the screen top.
            if origin.y + size.height > visible.maxY - 4 {
                origin.y = anchorScreenRect.minY - gap - size.height
            }
            origin.y = max(origin.y, visible.minY + 4)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
    }

    /// Hides the card iff `spaceId` is the one currently shown.
    func dismiss(spaceId: String) {
        guard ownerId == spaceId else { return }
        ownerId = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
        return panel
    }
}

/// Invisible SwiftUI ↔ AppKit bridge placed behind a pip. It reports the pip's
/// screen frame to `SpaceHoverTooltipController` and shows/hides the card as the
/// pip's hover state changes — without participating in event handling itself.
private struct SpaceTooltipAnchor: NSViewRepresentable {
    let isPresented: Bool
    let spaceId: String
    let card: AnyView
    let controller: SpaceHoverTooltipController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, spaceId: spaceId) }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.spaceId = spaceId
        guard isPresented, let window = nsView.window else {
            controller.dismiss(spaceId: spaceId)
            return
        }
        let rectInWindow = nsView.convert(nsView.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        controller.present(spaceId: spaceId, card: card, anchorScreenRect: screenRect, screen: window.screen)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // The pip left the hierarchy (e.g. overflow recompute) while its card was
        // up; tear the card down so it can't linger.
        coordinator.controller.dismiss(spaceId: coordinator.spaceId)
    }

    final class Coordinator {
        var controller: SpaceHoverTooltipController
        var spaceId: String
        init(controller: SpaceHoverTooltipController, spaceId: String) {
            self.controller = controller
            self.spaceId = spaceId
        }
    }
}
