// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import Foundation

/// One row from the Chromium-side profile attributes store, projected to
/// Swift. `profileId` is the on-disk basename and the wire identifier used
/// in every bridge call. `isInUse` reflects whether a live Chromium Browser
/// is currently bound to this profile (orthogonal to whether a `SpaceModel`
/// references it — that check lives on `SpaceManager`).
struct PhiBrowserProfile: Hashable, Identifiable {
    let profileId: String
    let displayName: String
    let isLoaded: Bool
    let isInUse: Bool

    var id: String { profileId }
}

/// One default-search-provider candidate for a profile, projected from
/// Chromium's TemplateURLService. `id` is the engine's stable sync GUID — the
/// wire identity used to set the default.
struct SearchEngineInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let keyword: String
    let isDefault: Bool
}

/// App-scoped owner of the Chromium profile list. The actual profile data
/// lives in Chromium's `ProfileAttributesStorage`; this class is a thin Swift
/// projection plus a publisher so views can observe changes.
///
/// CRUD goes through the bridge (`createProfileWithDisplayName:completion:`,
/// `deleteProfile:completion:`); after each mutation the manager refreshes
/// its cache so subscribers see the new shape. Lazy profile loading
/// (`ensureProfileLoaded:`) is driven from `SpaceManager.activate` and
/// doesn't change the published list.
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published private(set) var profiles: [PhiBrowserProfile] = []

    private init() {
        refresh()
    }

    // MARK: - Read

    /// Pulls the latest profile list from the bridge. Synchronous and
    /// cheap (Chromium-side just reads from in-memory ProfileAttributesStorage).
    /// Safe to call repeatedly on the main thread.
    func refresh() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            // Bridge not up yet at very early launch; `profiles` stays empty
            // and the first post-launch `refresh()` (driven by any UI that
            // needs profiles) will populate it.
            return
        }
        let raw = bridge.listProfiles()
        profiles = raw.compactMap(Self.decode(_:))
    }

    /// Convenience lookup — nil if the basename isn't known. Most callers
    /// only need the displayName for UI labelling.
    func profile(for profileId: String) -> PhiBrowserProfile? {
        profiles.first(where: { $0.profileId == profileId })
    }

    // MARK: - Mutations

    /// Creates a new on-disk profile. Completion fires on the main queue
    /// with the new profileId, or nil on failure. Refreshes the published
    /// list before completion fires.
    func createProfile(displayName: String,
                       completion: @escaping (String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(nil)
            return
        }
        bridge.createProfile(withDisplayName: displayName) { [weak self] newId in
            DispatchQueue.main.async {
                self?.refresh()
                if let newId {
                    self?.autoInstallICloudPasswordsIfNeeded(forProfile: newId)
                }
                completion(newId)
            }
        }
    }

    /// Mirrors the OOBE password-manager choice onto a newly created profile:
    /// when the user opted into iCloud Passwords during onboarding, silently
    /// install the iCloud Passwords extension into `profileId`. No-op otherwise.
    /// The Chromium `InstallByIds` path is idempotent, so if the profile later
    /// gets a window that also triggers an install, the duplicate is skipped.
    private func autoInstallICloudPasswordsIfNeeded(forProfile profileId: String) {
        guard PhiPreferences.PasswordManagerSettings.autoInstallICloudPasswords.loadValue() else {
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        bridge.ensureProfileLoaded(profileId) { success in
            DispatchQueue.main.async {
                guard success else {
                    AppLogWarn("[ProfileManager] iCloud auto-install: ensureProfileLoaded failed for \(profileId)")
                    return
                }
                bridge.installExtensions(withIds: [PhiExtensionID.icloudPasswords], profileId: profileId)
            }
        }
    }

    /// Schedules a profile for deletion. Completion fires on the main queue
    /// with success/error. The caller (UI) is expected to refuse the action
    /// up front when any Space is bound to this profile — see
    /// `SpaceManager.spaces`; the bridge enforces it as a backstop.
    func deleteProfile(_ profileId: String,
                       completion: @escaping (Bool, String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.deleteProfile(profileId) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.refresh()
                completion(success, error)
            }
        }
    }

    /// Renames a profile's display name. Completion fires on the main queue
    /// with success/error. Refreshes the published list before completion fires
    /// so subscribers observe the new name.
    func renameProfile(_ profileId: String,
                       to displayName: String,
                       completion: @escaping (Bool, String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.renameProfile(profileId, toDisplayName: displayName) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.refresh()
                completion(success, error)
            }
        }
    }

    // MARK: - Per-profile settings

    /// Lists a profile's search engines (default-search-provider candidates).
    /// Completion fires on the main queue; empty on failure. May load the
    /// profile first, so the callback can be delayed for an off profile.
    func searchEngines(forProfile profileId: String,
                       completion: @escaping ([SearchEngineInfo]) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion([])
            return
        }
        bridge.listSearchEngines(profileId) { raw in
            DispatchQueue.main.async {
                completion((raw ?? []).compactMap(Self.decodeEngine(_:)))
            }
        }
    }

    /// Sets a profile's default search engine (by sync GUID). Completion fires
    /// on the main queue with success/error.
    func setDefaultSearchEngine(_ engineId: String,
                                forProfile profileId: String,
                                completion: @escaping (Bool, String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.setDefaultSearchEngine(profileId, engineId: engineId) { success, error in
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    /// Reads a profile's default download directory. Completion fires on the
    /// main queue; nil on failure.
    func downloadLocation(forProfile profileId: String,
                          completion: @escaping (String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(nil)
            return
        }
        bridge.getDownloadLocation(profileId) { path in
            DispatchQueue.main.async { completion(path) }
        }
    }

    /// Sets a profile's default download directory. Completion fires on the main
    /// queue with success/error.
    func setDownloadLocation(_ path: String,
                             forProfile profileId: String,
                             completion: @escaping (Bool, String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.setDownloadLocation(profileId, path: path) { success, error in
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    /// Opens one of a profile's data/settings pages ("privacy", "passwords",
    /// "payments", "notifications", "clearBrowserData") in a browser window for
    /// that profile. Completion fires on the main queue with success/error.
    func openDataPage(_ page: String,
                      forProfile profileId: String,
                      completion: @escaping (Bool, String?) -> Void = { _, _ in }) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.openProfileDataPage(profileId, page: page) { success, error in
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    // MARK: - Wire decoding

    private static func decode(_ dict: [String: Any]) -> PhiBrowserProfile? {
        guard let id = dict["profileId"] as? String,
              let name = dict["displayName"] as? String else {
            return nil
        }
        let loaded = (dict["isLoaded"] as? NSNumber)?.boolValue ?? false
        let inUse = (dict["isInUse"] as? NSNumber)?.boolValue ?? false
        return PhiBrowserProfile(
            profileId: id,
            displayName: name,
            isLoaded: loaded,
            isInUse: inUse
        )
    }

    private static func decodeEngine(_ dict: [String: Any]) -> SearchEngineInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else {
            return nil
        }
        let keyword = dict["keyword"] as? String ?? ""
        let isDefault = (dict["isDefault"] as? NSNumber)?.boolValue ?? false
        return SearchEngineInfo(id: id, name: name, keyword: keyword, isDefault: isDefault)
    }
}
