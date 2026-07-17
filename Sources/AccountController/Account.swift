// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

class Account {
    let userID: String
    lazy var localStorage: LocalStore = {
        // Under UI testing the store is redirected to a throwaway per-launch
        // temp directory so tests never read or mutate the real account's
        // Spaces, bookmarks, or pinned tabs. See `uiTestStoreDirectoryURL`.
        if let testStoreURL = Account.uiTestStoreDirectoryURL {
            return LocalStore(account: self, storeDirectoryURL: testStoreURL)
        }
        return LocalStore(account: self)
    }()
    private(set) lazy var userDefaults: AccountUserDefaults = {
        AccountUserDefaults(account: self)
    }()
    
    init(userID: String) {
        self.userID = userID
    }
    
    var userDataStorage: URL {
        let phiDataSupportURL = URL(filePath:  FileSystemUtils.phiBrowserDataDirectory())
        return phiDataSupportURL
            .appendingPathComponent("users")
            .appendingPathComponent(userID)
    }
}

extension Account {
    private static let fallbackUid = "default-account-id"
    static let defaultUid = resolveLocalUserID()

    static var defaultAccount: Account {
        return Account(userID: defaultUid)
    }

    /// Reuses the most recently active legacy account directory when one is
    /// already present. Authentication is intentionally gone, but the user's
    /// Spaces, bookmarks, and other Swift-side browser state remain valuable
    /// local data and should not become inaccessible behind the old account id.
    private static func resolveLocalUserID() -> String {
        let usersURL = URL(filePath: FileSystemUtils.phiBrowserDataDirectory(), directoryHint: .isDirectory)
            .appendingPathComponent("users", isDirectory: true)
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["PHI_LOCAL_ACCOUNT_ID"],
           isUsableAccountDirectory(usersURL.appendingPathComponent(override, isDirectory: true), fileManager: fileManager) {
            return override
        }

        guard let accountURLs = try? fileManager.contentsOfDirectory(
            at: usersURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return fallbackUid
        }

        let legacyAccounts = accountURLs.filter {
            $0.lastPathComponent != fallbackUid && isUsableAccountDirectory($0, fileManager: fileManager)
        }
        guard !legacyAccounts.isEmpty else { return fallbackUid }

        return legacyAccounts.max { lhs, rhs in
            accountModificationDate(lhs, fileManager: fileManager)
                < accountModificationDate(rhs, fileManager: fileManager)
        }?.lastPathComponent ?? fallbackUid
    }

    private static func isUsableAccountDirectory(_ accountURL: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(
            atPath: accountURL
                .appendingPathComponent("localDB", isDirectory: true)
                .appendingPathComponent("LocalStore.sqlite", isDirectory: false)
                .path
        )
    }

    private static func accountModificationDate(_ accountURL: URL, fileManager: FileManager) -> Date {
        let localDB = accountURL.appendingPathComponent("localDB", isDirectory: true)
        let candidates = ["LocalStore.sqlite-wal", "LocalStore.sqlite"]
        return candidates.compactMap { name in
            let path = localDB.appendingPathComponent(name, isDirectory: false).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return nil }
            return attributes[.modificationDate] as? Date
        }.max() ?? .distantPast
    }

    /// A unique-per-launch temp directory for the `LocalStore` when the app is
    /// launched for UI testing (`-uitest`); otherwise nil. Isolating the store
    /// keeps UI tests from reading or writing the real account's Spaces,
    /// bookmarks, and pinned tabs — the Chromium `--user-data-dir` does not
    /// cover this Swift-side, per-account store. Computed once per process.
    static let uiTestStoreDirectoryURL: URL? = {
        guard ProcessInfo.processInfo.arguments.contains("-uitest") else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "PhiUITestStore-\(ProcessInfo.processInfo.globallyUniqueString)",
                isDirectory: true
            )
    }()
}

class AccountController {
    static let shared = AccountController()
    var account: Account? {
        willSet {
            guard account !== newValue else { return }
            account?.userDefaults.flush()
        }
        didSet {
            NotificationCenter.default.post(name: .mainAccountChanged, object: account)
            /// FIXME: Chromium builds the main menu before the account exists, but shortcut overrides
            /// are account-scoped. Reloading here works, but this probably deserves a cleaner hook.
            Shortcuts.reloadOverrides()
            AppLogInfo("account controller created: \(String(describing: account?.userID))")
        }
    }
    
    static var defaultAccount: Account = Account.defaultAccount
}

extension Notification.Name {
    static let mainAccountChanged = Notification.Name("mainAccountDidChange")
}
