// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import SwiftData
class BrowserDataImporter {
    enum Phase {
        case waiting
        case importingChromeData
        case importingSafariData
        case importingArcData
        case done
    }

    struct ChromeProfileInfo: Equatable {
        let directory: String
        let name: String
        let email: String?
    }

    private(set) var targetProfileId: String
    private(set) var targetSpaceId: String
    private(set) var targetWindowId: Int?

    /// True from the moment an import starts until its deferred bookmark
    /// persistence finishes. While true the target must not be rebound, or the
    /// pending snapshot would be saved into the newly-bound Space instead of
    /// the one the running import was started for.
    private(set) var isImporting = false

    // Continuations for active import requests, keyed by browser type.
    private var importContinuations: [BrowserType: CheckedContinuation<Bool, Never>] = [:]
    private let continuationQueue = DispatchQueue(label: "com.phibrowser.import.continuation")
    
    private(set) var failedImports: [BrowserType] = []
    @Published private(set) var phase: Phase = .waiting
    @Published var status: String = ""
    
    init(targetProfileId: String = LocalStore.defaultProfileId, targetSpaceId: String = LocalStore.defaultSpaceId, targetWindowId: Int? = nil) {
        self.targetProfileId = targetProfileId
        self.targetSpaceId = targetSpaceId
        self.targetWindowId = targetWindowId
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImportCompleted(_:)),
            name: .browserImportCompleted,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Retargets a future import to a different window/profile/Space when the
    /// single import window is re-invoked from another Space. Callers must skip
    /// this while `isImporting` is true so the in-flight import keeps its
    /// original destination.
    func updateTarget(profileId: String, spaceId: String, windowId: Int?) {
        targetProfileId = profileId
        targetSpaceId = spaceId
        targetWindowId = windowId
    }

    /// Starts importing data from the selected browsers. Returns `false` only
    /// when the call was ignored because an import is already in flight, so the
    /// caller can skip its completion handler instead of advancing/closing the
    /// UI out from under the running import.
    @MainActor
    @discardableResult
    func startImportData(_ options: [BrowserType], chromeProfileDirectory: String? = nil, dataTypesPerBrowser: [BrowserType: [String]]? = nil) async -> Bool {
        // Prefer the caller-provided window so Chromium import state follows the initiating window/profile.
        guard let windowId = targetWindowId ?? MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() else {
            AppLogError("No available window for import")
            return true
        }

        // Reentrancy gate: a second start (rapid double-click, repeated action
        // dispatch, programmatic re-call) while an import is unresolved would
        // overwrite the BrowserType-keyed continuation and race the shared
        // Chromium bookmark staging. @MainActor plus setting the flag with no
        // preceding await makes this check atomic against a queued second call.
        // Returning false lets the caller skip its completion for this ignored start.
        guard !isImporting else {
            AppLogInfo("Import already in progress; ignoring re-entrant start")
            return false
        }
        isImporting = true
        failedImports.removeAll()

        // Only clear bookmarks if at least one browser is importing bookmarks
        let importingBookmarks = options.contains { option in
            guard let types = dataTypesPerBrowser?[option] else { return true } // nil = import all
            return types.contains(ImportDataType.bookmarks.rawValue)
        }
        if importingBookmarks {
            ChromiumLauncher.sharedInstance().bridge?.removeAllBookmarks(withWindowId: windowId.int64Value)
        }

        for option in options {
            updatePhase(option)

            // For Arc, bookmarks are handled separately via ArcDataParserTool.
            // Only send non-bookmark types to the bridge.
            var bridgeDataTypes = dataTypesPerBrowser?[option]
            if option == .arc {
                bridgeDataTypes = bridgeDataTypes?.filter { $0 != ImportDataType.bookmarks.rawValue }
            }

            if option != .arc || !(bridgeDataTypes?.isEmpty ?? true) {
                let success = await importData(
                    option,
                    windowId: windowId,
                    chromeProfileDirectory: chromeProfileDirectory,
                    dataTypes: bridgeDataTypes
                )

                if !success {
                    failedImports.append(option)
                }

                AppLogInfo("Import from \(option) completed with success: \(success)")
            }
        }

        // Arc bookmarks: parse locally if user selected bookmarks for Arc
        let arcBookmarks: [ArcDataParserTool.Bookmark]
        let arcWantsBookmarks = dataTypesPerBrowser?[.arc]?.contains(ImportDataType.bookmarks.rawValue) ?? true
        if options.contains(.arc), arcWantsBookmarks, let arcData = getArcSidebarData() {
            do {
                arcBookmarks = try ArcDataParserTool.parse(data: arcData)
            } catch {
                AppLogError("\(error.localizedDescription)")
                arcBookmarks = []
            }
        } else {
            arcBookmarks = []
        }

        updateCompletionStatus()

        if importingBookmarks || !arcBookmarks.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                await self.persistImportedBookmarksAfterSnapshot(
                    windowId: windowId,
                    arcBookmarks: arcBookmarks
                )
                await MainActor.run { self.isImporting = false }
            }
        } else {
            isImporting = false
        }

        return true
    }
    
    
    private func getArcSidebarData() -> Data? {
         let localStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
        return try? Data(contentsOf: localStateURL)
    }
    
    /// Imports data for one browser using a continuation-backed async flow.
    private func importData(
        _ option: BrowserType,
        windowId: Int,
        chromeProfileDirectory: String?,
        dataTypes: [String]?
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            continuationQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }

                self.importContinuations[option] = continuation

                DispatchQueue.main.async {
                    let profile = (option == .chrome ? chromeProfileDirectory : nil) ?? ""
                    ChromiumLauncher.sharedInstance().bridge?.importBrowserData(
                        from: option,
                        profile: profile,
                        dataTypes: dataTypes,
                        windowId: Int64(windowId)
                    )
                }
            }
        }
    }
    
    /// Handles the completion callback emitted by the Chromium bridge.
    @objc private func handleImportCompleted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let browserTypeRaw = userInfo["browserType"] as? UInt,
              let browserType = BrowserType(rawValue: browserTypeRaw),
              let success = userInfo["success"] as? Bool else {
            AppLogError("Invalid import completion notification")
            return
        }
        
        continuationQueue.async { [weak self] in
            guard let self = self,
                  let continuation = self.importContinuations.removeValue(forKey: browserType) else {
                AppLogError("No continuation found for browser type: \(browserType)")
                return
            }
            
            continuation.resume(returning: success)
        }
    }
    
    /// Updates the current import phase and status text.
    private func updatePhase(_ option: BrowserType) {
        switch option {
        case .arc:
            phase = .importingArcData
            status = NSLocalizedString("Importing Arc data...", comment: "Browser data importer - Status message while importing Arc browser data")
        case .chrome:
            phase = .importingChromeData
            status = NSLocalizedString("Importing Chrome data...", comment: "Browser data importer - Status message while importing Chrome browser data")
        case .safari:
            phase = .importingSafariData
            status = NSLocalizedString("Importing Safari data...", comment: "Browser data importer - Status message while importing Safari browser data")
        @unknown default:
            phase = .waiting
            status = ""
        }
    }
    
    private func updateCompletionStatus() {
        phase = .done
        if failedImports.isEmpty {
            status = NSLocalizedString("Import completed successfully", comment: "Browser data importer - Status message when all imports completed successfully")
        } else {
            let failedBrowserNames = failedImports.map { browserName(for: $0) }.joined(separator: ", ")
            let format = NSLocalizedString("Import completed with errors. Failed to import from: %@", comment: "Browser data importer - Status message when some imports failed, shows list of failed browsers")
            status = String(format: format, failedBrowserNames)
        }
    }
    
    /// Returns the user-facing browser name.
    private func browserName(for type: BrowserType) -> String {
        switch type {
        case .chrome:
            return "Chrome"
        case .safari:
            return "Safari"
        case .arc:
            return "Arc"
        @unknown default:
            return "Unknown"
        }
    }

    private func persistImportedBookmarksAfterSnapshot(
        windowId: Int,
        arcBookmarks: [ArcDataParserTool.Bookmark]
    ) async {
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)

        let bookmarkWrappers = await MainActor.run {
            ChromiumLauncher
                .sharedInstance()
                .bridge?
                .getAllBookmarks(withWindowId: windowId.int64Value)
        }

        await AccountController.shared.account?
            .localStorage
            .saveChromiumBookmarksToLocalStore(
                bookmarkWrappers ?? [],
                profileId: targetProfileId,
                spaceId: targetSpaceId
            )

        if !arcBookmarks.isEmpty {
            await AccountController.shared.account?.localStorage.saveArcBookmarksToLocalStore(
                arcBookmarks,
                profileId: targetProfileId,
                spaceId: targetSpaceId
            )
        }

        await AccountController.shared.account?.localStorage.reorderImportedBrowserFolders(
            profileId: targetProfileId,
            spaceId: targetSpaceId
        )
    }

    func loadChromeProfiles() -> [ChromeProfileInfo] {
        let localStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: localStateURL) else {
            AppLogError("Unable to read Chrome Local State at \(localStateURL.path)")
            return []
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = root["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: Any],
            let profilesOrder = profile["profiles_order"] as? [String]
        else {
            AppLogError("Invalid Chrome Local State profile structure")
            return []
        }

        var results: [ChromeProfileInfo] = []
        results.reserveCapacity(profilesOrder.count)
        for directory in profilesOrder {
            guard let info = infoCache[directory] as? [String: Any] else {
                continue
            }
            let name = (info["name"] as? String) ?? directory
            let email = info["user_name"] as? String
            results.append(ChromeProfileInfo(directory: directory, name: name, email: email))
        }

        return results
    }
}

// MARK: - Notification Name
extension Notification.Name {
    static let browserImportCompleted = Notification.Name("browserImportCompleted")
}
