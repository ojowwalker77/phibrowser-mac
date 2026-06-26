// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// Settings pane content for managing Chromium profiles, laid out master-detail:
/// the profile list on the left (with a +/−/✎ toolbar) and the selected
/// profile's per-profile browser settings on the right (search engine, download
/// location, and quick links into that profile's data & settings pages).
/// Profile lifecycle routes through `ProfileManager`; `SpaceManager` is observed
/// for each profile's Space count and the delete guard. The per-profile settings
/// round-trip to Chromium via `ProfileManager`'s bridge accessors and may load
/// the profile on first access.
struct ProfilesSettingsView: View {
    @ObservedObject private var spaceManager = SpaceManager.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    @State private var selectedProfileId: String?
    @State private var searchEngines: [SearchEngineInfo] = []
    @State private var defaultEngineId: String = ""
    @State private var downloadPath: String = ""
    @State private var isLoadingDetail: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            profileListPanel
                .frame(width: 210)
                .frame(maxHeight: .infinity)
            detailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .onAppear {
            profileManager.refresh()
            if selectedProfileId == nil { selectInitialProfile() }
        }
        // Keep the selection valid as the profile list changes (create/delete).
        .onChange(of: profileManager.profiles.map(\.profileId)) { ids in
            if let sel = selectedProfileId, ids.contains(sel) { return }
            selectInitialProfile()
        }
    }

    // MARK: - Left: profile list

    private var profileListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("Your Profiles", comment: "Profiles settings - list header"))
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            SettingsRowDivider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(profileManager.profiles) { profile in
                        profileListRow(profile)
                    }
                }
                .padding(6)
            }

            SettingsRowDivider()

            HStack(spacing: 0) {
                toolbarButton(systemName: "plus",
                              help: NSLocalizedString("New profile", comment: "Profiles settings - new profile tooltip"),
                              action: newProfile)
                toolbarDivider
                toolbarButton(systemName: "minus",
                              help: NSLocalizedString("Delete selected profile", comment: "Profiles settings - delete profile tooltip"),
                              disabled: !canDeleteSelected,
                              action: deleteSelected)
                toolbarDivider
                toolbarButton(systemName: "pencil",
                              help: NSLocalizedString("Rename selected profile", comment: "Profiles settings - rename profile tooltip"),
                              disabled: selectedProfile == nil,
                              action: renameSelected)
                Spacer()
            }
            .frame(height: 34)
        }
        .settingsCardChrome()
    }

    private func profileListRow(_ profile: PhiBrowserProfile) -> some View {
        let isSelected = profile.profileId == selectedProfileId
        let isDefault = profile.profileId == LocalStore.defaultProfileId
        let count = spaceManager.spaces.filter { $0.profileId == profile.profileId }.count
        return Button {
            select(profile.profileId)
        } label: {
            HStack(spacing: 6) {
                Text(profile.displayName)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                    .lineLimit(1)
                if isDefault {
                    SettingsDefaultBadge()
                }
                Spacer(minLength: 4)
                Text(count == 0
                     ? NSLocalizedString("Not used", comment: "Profiles settings - tag for a profile with no Spaces")
                     : spaceCountLabel(count))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toolbarButton(systemName: String,
                               help: String,
                               disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.7))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color(.separatorColor))
            .frame(width: 1, height: 20)
    }

    // MARK: - Right: per-profile settings

    @ViewBuilder
    private var detailPanel: some View {
        if let profileId = selectedProfileId {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsDetailCard {
                        SettingsDetailRow(NSLocalizedString("Search engine", comment: "Profiles settings - search engine row label"),
                                          systemImage: "magnifyingglass") {
                            searchEngineControl(profileId: profileId)
                        }
                        SettingsRowDivider()
                        SettingsDetailRow(NSLocalizedString("Download location", comment: "Profiles settings - download location row label"),
                                          systemImage: "arrow.down.to.line") {
                            downloadLocationControl(profileId: profileId)
                        }
                    }
                    dataAndSettingsSection(profileId: profileId)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(NSLocalizedString("Select a profile to view its settings.",
                                   comment: "Profiles settings - empty detail placeholder"))
                .font(.system(size: 13))
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func searchEngineControl(profileId: String) -> some View {
        if isLoadingDetail {
            ProgressView().controlSize(.small)
        } else if searchEngines.isEmpty {
            Text(NSLocalizedString("Unavailable", comment: "Profiles settings - search engine list unavailable"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
        } else {
            // Custom pill matching the download-location control (and the Spaces
            // pane's themeControl) so both rows' selectors share one height,
            // style, and trailing edge instead of the native picker's taller,
            // differently-inset bezel.
            Menu {
                Picker("", selection: searchBinding(profileId)) {
                    ForEach(searchEngines) { engine in
                        Text(engine.name).tag(engine.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Text(selectedEngineName)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .themedForeground(.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            // .button + .plain renders the label exactly as given (like the
            // download Button's pill); .borderlessButton would impose a native
            // popup look instead, dropping the pill and its trailing chevron.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var selectedEngineName: String {
        searchEngines.first(where: { $0.id == defaultEngineId })?.name ?? ""
    }

    @ViewBuilder
    private func downloadLocationControl(profileId: String) -> some View {
        if isLoadingDetail {
            ProgressView().controlSize(.small)
        } else {
            Button {
                chooseDownloadLocation(profileId: profileId)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                    Text(downloadFolderName)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .themedForeground(.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private var downloadFolderName: String {
        guard !downloadPath.isEmpty else {
            return NSLocalizedString("Choose…", comment: "Profiles settings - download location not set")
        }
        return (downloadPath as NSString).lastPathComponent
    }

    // MARK: - Your Data and Settings links

    private struct DataLink: Identifiable {
        let page: String
        let title: String
        let systemImage: String
        var id: String { page }
    }

    private var dataLinks: [DataLink] {
        [
            DataLink(page: "privacy",
                     title: NSLocalizedString("Privacy and Security", comment: "Profiles settings - data link to privacy settings"),
                     systemImage: "lock.shield"),
            DataLink(page: "payments",
                     title: NSLocalizedString("Credit Cards", comment: "Profiles settings - data link to payment methods"),
                     systemImage: "creditcard"),
            DataLink(page: "notifications",
                     title: NSLocalizedString("Notifications", comment: "Profiles settings - data link to notification settings"),
                     systemImage: "bell"),
            DataLink(page: "clearBrowserData",
                     title: NSLocalizedString("Clear Browsing Data", comment: "Profiles settings - data link to clear browsing data"),
                     systemImage: "trash"),
        ]
    }

    @ViewBuilder
    private func dataAndSettingsSection(profileId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Your Data and Settings", comment: "Profiles settings - data & settings section header"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .padding(.leading, 2)
            SettingsDetailCard {
                ForEach(Array(dataLinks.enumerated()), id: \.element.page) { index, link in
                    if index > 0 { SettingsRowDivider() }
                    dataLinkRow(link, profileId: profileId)
                }
            }
        }
    }

    private func dataLinkRow(_ link: DataLink, profileId: String) -> some View {
        Button {
            profileManager.openDataPage(link.page, forProfile: profileId)
        } label: {
            SettingsDetailRow(link.title, systemImage: link.systemImage) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection + detail loading

    private var selectedProfile: PhiBrowserProfile? {
        guard let id = selectedProfileId else { return nil }
        return profileManager.profiles.first(where: { $0.profileId == id })
    }

    private var canDeleteSelected: Bool {
        guard let profile = selectedProfile,
              profile.profileId != LocalStore.defaultProfileId else { return false }
        return spaceManager.spaces.allSatisfy { $0.profileId != profile.profileId }
    }

    private func selectInitialProfile() {
        let preferred = profileManager.profiles.first(where: { $0.profileId == LocalStore.defaultProfileId })
            ?? profileManager.profiles.first
        if let profile = preferred {
            select(profile.profileId)
        } else {
            selectedProfileId = nil
        }
    }

    private func select(_ profileId: String) {
        selectedProfileId = profileId
        loadDetail(profileId)
    }

    /// Loads the selected profile's search engines and download location and
    /// swaps the new values in place. The previously shown controls stay put
    /// until the new data arrives — no clear-and-spinner on switch — so changing
    /// profiles doesn't flash: the bridge always answers a runloop later, which
    /// used to make the wiped, mid-load state briefly visible. Only the first
    /// load, when there's nothing cached to keep, shows the loading placeholder.
    ///
    /// Both round-trips guard on the still-selected profile so a fast profile
    /// switch can't let a slow off-profile load clobber the newer selection.
    private func loadDetail(_ profileId: String) {
        // Keep whatever's on screen; only show the loading state when there's
        // nothing cached to keep (first load).
        isLoadingDetail = searchEngines.isEmpty
        profileManager.searchEngines(forProfile: profileId) { engines in
            guard selectedProfileId == profileId else { return }
            searchEngines = engines
            defaultEngineId = engines.first(where: { $0.isDefault })?.id ?? engines.first?.id ?? ""
            isLoadingDetail = false
        }
        profileManager.downloadLocation(forProfile: profileId) { path in
            guard selectedProfileId == profileId else { return }
            downloadPath = path ?? ""
        }
    }

    private func searchBinding(_ profileId: String) -> Binding<String> {
        Binding(
            get: { defaultEngineId },
            set: { newId in
                guard newId != defaultEngineId else { return }
                let previous = defaultEngineId
                defaultEngineId = newId
                profileManager.setDefaultSearchEngine(newId, forProfile: profileId) { success, _ in
                    if !success, selectedProfileId == profileId { defaultEngineId = previous }
                }
            }
        )
    }

    private func chooseDownloadLocation(profileId: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Choose", comment: "Profiles settings - download folder picker confirm button")
        panel.message = NSLocalizedString("Choose a download location for this profile.",
                                          comment: "Profiles settings - download folder picker message")
        if !downloadPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: downloadPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let newPath = url.path
        let previous = downloadPath
        downloadPath = newPath
        profileManager.setDownloadLocation(newPath, forProfile: profileId) { success, _ in
            if !success, selectedProfileId == profileId { downloadPath = previous }
        }
    }

    // MARK: - Helpers

    private func spaceCountLabel(_ count: Int) -> String {
        String(format: NSLocalizedString("%d Spaces", comment: "Profiles settings - Count of Spaces bound to a profile"), count)
    }

    // MARK: - Actions

    private func deleteSelected() {
        guard let profile = selectedProfile else { return }
        deleteProfile(profile)
    }

    private func renameSelected() {
        guard let profile = selectedProfile else { return }
        renameProfile(profile)
    }

    private func newProfile() {
        // Re-prompt on an empty name instead of silently dropping it, so the
        // user is told the name is required rather than left wondering why
        // "Create" did nothing.
        var showEmptyError = false
        while true {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("New Profile", comment: "Title of the create-profile dialog")
            alert.informativeText = showEmptyError
                ? NSLocalizedString("The name cannot be empty.",
                    comment: "Validation shown when the profile name is left blank")
                : NSLocalizedString(
                    "Enter a name for the new profile. Each profile has its own cookies, history, and extensions.",
                    comment: "Body of the create-profile dialog")
            alert.addButton(withTitle: NSLocalizedString("Create", comment: "Create button"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            textField.placeholderString = NSLocalizedString("Profile name", comment: "Placeholder for the profile-name field")
            alert.accessoryView = textField
            DispatchQueue.main.async {
                textField.window?.makeFirstResponder(textField)
            }
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                showEmptyError = true
                continue
            }
            profileManager.createProfile(displayName: trimmed) { newId in
                if let newId { select(newId) }
            }
            return
        }
    }

    private func renameProfile(_ profile: PhiBrowserProfile) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Rename Profile", comment: "Title of the rename-profile dialog")
        alert.informativeText = NSLocalizedString("Enter a new name for this profile.", comment: "Body of the rename-profile dialog")
        alert.addButton(withTitle: NSLocalizedString("Rename", comment: "Rename button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = profile.displayName
        textField.placeholderString = profile.displayName
        alert.accessoryView = textField
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
            textField.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.displayName else { return }
        profileManager.renameProfile(profile.profileId, to: trimmed) { success, error in
            if !success {
                let errAlert = NSAlert()
                errAlert.messageText = NSLocalizedString("Couldn't rename profile", comment: "Title of the profile-rename error")
                errAlert.informativeText = error ?? NSLocalizedString("Unknown error", comment: "Fallback profile-rename error reason")
                errAlert.runModal()
            }
        }
    }

    private func deleteProfile(_ profile: PhiBrowserProfile) {
        guard profile.profileId != LocalStore.defaultProfileId else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete profile \u{201C}%@\u{201D}?", comment: "Title of the delete-profile confirmation"),
            profile.displayName
        )
        alert.informativeText = NSLocalizedString(
            "All cookies, history, extensions, and saved data on this profile will be permanently removed. This cannot be undone.",
            comment: "Body of the delete-profile confirmation"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profileManager.deleteProfile(profile.profileId) { success, error in
            if !success {
                let errAlert = NSAlert()
                errAlert.messageText = NSLocalizedString("Couldn't delete profile", comment: "Title of the profile-delete error")
                errAlert.informativeText = error ?? NSLocalizedString("Unknown error", comment: "Fallback profile-delete error reason")
                errAlert.runModal()
            }
        }
    }
}
