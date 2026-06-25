// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Rich "Create a Space" panel. Replaces the bare name-only NSAlert that used
/// to back both the File menu and the Spaces picker's "New Space" row. Lets the
/// user name the Space, bind it to a profile, and pick its theme (or Follow
/// Global) before committing.
///
/// Self-contained: the only side effect is `manager.createSpace(...)` on
/// confirm. Presented in a chrome-light floating window via `present(...)`,
/// which both entry points call so the window setup lives in one place.
struct CreateSpacePanel: View {
    enum Style {
        /// Floating window — used in the horizontal (Comfortable) layout and
        /// whenever no usable sidebar is available.
        case window
        /// Fills the sidebar in vertical (Performance / Balanced) layouts.
        case sidebar
    }

    var style: Style = .window
    @ObservedObject var manager: SpaceManager
    @ObservedObject var profileManager: ProfileManager
    /// Profile the picker opens on — the active Space's profile when reached
    /// from the sidebar, or the menu's active-window profile.
    let initialProfileId: String?
    let onClose: () -> Void

    @State private var name: String = ""
    /// Icon/emoji pinned to the new Space, chosen from the same picker the
    /// Spaces settings pane uses. Defaults to the picker's first Phi icon.
    @State private var selectedIcon: IconPickerSelection = .defaultSelection
    @State private var selectedProfileId: String = ""
    /// Built-in theme id pinned to the new Space. Pre-selected in `onAppear`;
    /// the form always pins a concrete theme — no "follow global" option here.
    @State private var selectedThemeId: String = Theme.default.id
    @FocusState private var nameFocused: Bool

    @Environment(\.phiAppearance) private var appearance

    private static let accentColor = Color(hexString: "#3AA4D5")

    var body: some View {
        styledContent
            .onAppear {
                selectedProfileId = resolvedInitialProfileId
                // Pre-select the active Space's pinned theme, falling back to
                // the current global theme when it follows global. The form has
                // no "follow global" option, so a concrete theme is always
                // pre-selected (and pinned on create).
                let inherited = manager.activeSpaceId.flatMap { manager.themeId(forSpaceId: $0) }
                selectedThemeId = inherited ?? ThemeManager.shared.currentTheme.id
                DispatchQueue.main.async { nameFocused = true }
            }
    }

    @ViewBuilder
    private var styledContent: some View {
        switch style {
        case .window:
            formStack
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(width: 320)
        case .sidebar:
            // Transparent so the themed visual-effect backdrop installed by
            // `SidebarViewController.showCreateSpaceOverlay` shows through —
            // the form then sits on the active Space's overlay color and
            // opacity instead of an opaque card that ignores the Space theme.
            // Scrolls rather than centers: the embedded icon grid makes the form
            // taller than a short sidebar, so the create button must stay
            // reachable.
            ScrollView {
                formStack
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
    }

    private var formStack: some View {
        VStack(spacing: 28) {
            header
            form
            actions
        }
        // One bounded, centered column so every element shares a width and the
        // form never stretches across a wide sidebar. In a narrower sidebar it
        // shrinks to fit; the icon grid reflows to match.
        .frame(maxWidth: Self.contentWidth)
    }

    private static let contentWidth: CGFloat = 280

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Text(NSLocalizedString("Create a Space",
                comment: "Title of the create-Space panel"))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
            Text(NSLocalizedString("Each space has its own independent bookmarks",
                comment: "Subtitle of the create-Space panel"))
                .font(.system(size: 14))
                .foregroundStyle(Color.primary.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(spacing: 4) {
            nameField
            profileRow
            iconBlock
            colorBlock
        }
    }

    /// Inline icon/emoji picker, mirroring the Spaces settings pane so creating a
    /// Space offers the same chooser as editing one. A greedy `GeometryReader`
    /// reports the real column width so the picker fills it exactly (a plain
    /// `.frame(maxWidth:.infinity)` leaves the adaptive grid at its 1-column
    /// minimum, centered).
    private var iconBlock: some View {
        GeometryReader { geo in
            IconPicker(
                selected: selectedIcon,
                showsGroups: true,
                width: geo.size.width,
                onSelect: { selectedIcon = $0 }
            )
        }
        .frame(height: IconPicker.preferredHeight)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var nameField: some View {
        TextField(
            NSLocalizedString("Space name", comment: "Placeholder for the Space-name field"),
            text: $name
        )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($nameFocused)
            .onSubmit(create)
            .frame(height: 32)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profileRow: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("Profile",
                comment: "Label for the profile picker in the create-Space panel"))
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.85))
            Spacer(minLength: 0)
            profilePill
        }
        .frame(height: 32)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profilePill: some View {
        Menu {
            ForEach(profileManager.profiles, id: \.profileId) { profile in
                Button(profile.displayName) { selectedProfileId = profile.profileId }
            }
            Divider()
            Button {
                promptCreateProfile()
            } label: {
                Label(NSLocalizedString("New Profile\u{2026}",
                    comment: "Profile picker item to create a new profile"),
                    systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedProfileName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 20)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var colorBlock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Theme.builtInThemes, id: \.id) { theme in
                    themeDot(theme)
                        .frame(maxWidth: .infinity)
                }
            }
            Text(selectedThemeName)
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// One picker dot for a built-in theme.
    @ViewBuilder
    private func themeDot(_ theme: Theme) -> some View {
        let isPure = theme == .pure
        let accent = Color(theme.color(for: .themeColor, appearance: appearance))
        ThemeSwatchView(
            fillColor: isPure ? .white : accent,
            ringColor: accent,
            selected: selectedThemeId == theme.id,
            title: nil,
            showsContrastBorder: isPure,
            dotDiameter: 18,
            ringDiameter: 22,
            action: { selectedThemeId = theme.id }
        )
    }

    /// Name of the currently-selected theme.
    private var selectedThemeName: String {
        effectiveTheme().name
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: create) {
                Text(NSLocalizedString("Create Space",
                    comment: "Confirm button in the create-Space panel"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Self.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Text(NSLocalizedString("Cancel", comment: "Cancel button"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Color math

    /// The Space's stored `colorHex` (which drives the sidebar tint) is derived
    /// from the chosen theme's overlay color, so the tint always matches the
    /// Space's pinned theme.
    private func resolvedColorHex() -> String {
        effectiveTheme().color(for: .windowOverlayBackground, appearance: appearance).hexRGBString
    }

    /// The theme backing the new Space, resolved from the pinned selection.
    private func effectiveTheme() -> Theme {
        ThemeManager.shared.registeredThemes[selectedThemeId]
            ?? Theme.builtInThemes.first(where: { $0.id == selectedThemeId })
            ?? ThemeManager.shared.currentTheme
    }

    // MARK: - Profiles

    private var resolvedInitialProfileId: String {
        if let id = initialProfileId,
           profileManager.profiles.contains(where: { $0.profileId == id }) {
            return id
        }
        return profileManager.profiles.first?.profileId ?? LocalStore.defaultProfileId
    }

    private var selectedProfileName: String {
        profileManager.profile(for: selectedProfileId)?.displayName ?? selectedProfileId
    }

    /// Prompts for a name and creates a new profile, selecting it for this
    /// Space once the bridge reports the new id. Mirrors the menu's
    /// `newProfile` flow so both entry points behave identically.
    private func promptCreateProfile() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("New Profile",
            comment: "Title of the create-profile dialog")
        alert.informativeText = NSLocalizedString(
            "Enter a name for the new profile. Each profile has its own cookies, history, and extensions.",
            comment: "Body of the create-profile dialog")
        alert.addButton(withTitle: NSLocalizedString("Create", comment: "Create button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = NSLocalizedString("Profile name",
            comment: "Placeholder for the profile-name field")
        alert.accessoryView = textField
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profileManager.createProfile(displayName: trimmed) { newId in
            if let newId { selectedProfileId = newId }
        }
    }

    // MARK: - Commit

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
            ? String(format: NSLocalizedString("Space %d",
                comment: "Default name for a newly created Space"),
                manager.spaces.count + 1)
            : trimmed
        let profileId = selectedProfileId.isEmpty ? resolvedInitialProfileId : selectedProfileId
        let newSpaceId = manager.createSpace(
            name: finalName,
            colorHex: resolvedColorHex(),
            iconName: selectedIcon.storageValue,
            profileId: profileId
        )
        // Pin the new Space's chosen theme. Persisted now; applied when its
        // window spawns in activateInFocusedWindow.
        if let newSpaceId {
            manager.setTheme(forSpaceId: newSpaceId, themeId: selectedThemeId)
        }
        onClose()
        // Bring the freshly created Space to the front of the active window.
        // `createSpace` only records it as the persisted default, so without
        // this the current window would stay on the Space we created from — in
        // both the sidebar (vertical) and floating-panel (horizontal) flows.
        // Runs after `onClose` so the overlay / panel is torn down first and the
        // switch animation plays over the revealed sidebar rather than under it.
        if let newSpaceId {
            manager.activateInFocusedWindow(spaceId: newSpaceId)
        }
    }
}

// MARK: - Presentation

extension CreateSpacePanel {
    private static let windowIdentifier = "Phi Create Space"

    /// Single entry point for "New Space" from the menu or the Spaces picker.
    /// Vertical layouts (Performance / Balanced) show the form inline in the
    /// sidebar; the horizontal layout (Comfortable) — or any window without a
    /// usable sidebar — falls back to the floating window.
    static func requestCreation(initialProfileId: String?) {
        if let wc = MainBrowserWindowControllersManager.shared.activeWindowController,
           !wc.browserState.layoutMode.isTraditional {
            let sidebar = wc.mainSplitViewController.sidebarViewController
            if sidebar.isViewLoaded, sidebar.view.window != nil, sidebar.view.bounds.width > 120 {
                sidebar.showCreateSpaceOverlay(initialProfileId: initialProfileId)
                return
            }
        }
        present(manager: .shared, initialProfileId: initialProfileId)
    }

    /// Brings up the create-Space panel in a single shared, chrome-light
    /// window. Reuses an already-open window so repeated invocations from the
    /// menu or the picker don't stack duplicates.
    @discardableResult
    static func present(manager: SpaceManager,
                        profileManager: ProfileManager = .shared,
                        initialProfileId: String?) -> NSWindow {
        if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue == windowIdentifier
        }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let panel = CreateSpacePanel(
            manager: manager,
            profileManager: profileManager,
            initialProfileId: initialProfileId
        ) { [weak window] in
            window?.close()
        }
        let hosting = ThemedHostingController(rootView: panel)
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
}
