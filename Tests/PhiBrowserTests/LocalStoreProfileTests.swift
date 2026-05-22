// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import SwiftData
@testable import Phi

@MainActor
final class LocalStoreProfileTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testMigratingLegacyStoreAssignsRowsToDefaultProfile() throws {
        let directory = try makeTemporaryStoreDirectory()
        try seedLegacyStore(at: directory)

        let store = LocalStore(
            account: Account(userID: "legacy-account"),
            storeDirectoryURL: directory
        )
        let context = try XCTUnwrap(store.getMainContext())

        let profiles: [ProfileModel] = try context.fetch(FetchDescriptor<ProfileModel>())
        XCTAssertEqual(profiles.map { $0.profileId }, ["Default"])

        let tabs: [TabDataModel] = try context.fetch(FetchDescriptor<TabDataModel>())
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.profile?.profileId, "Default")
    }

    func testGetAllPinnedTabsFiltersByProfileId() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(profileId: "Default")
        let workProfile = ProfileModel(profileId: "Work")
        context.insert(defaultProfile)
        context.insert(workProfile)

        let defaultPinned = makeTab(guid: "default-pinned", title: "Default", url: "https://default.example")
        defaultPinned.dataType = TabDataType.pinnedTab
        defaultPinned.profile = defaultProfile
        context.insert(defaultPinned)

        let workPinned = makeTab(guid: "work-pinned", title: "Work", url: "https://work.example")
        workPinned.dataType = TabDataType.pinnedTab
        workPinned.profile = workProfile
        context.insert(workPinned)

        try context.save()

        XCTAssertEqual(store.getAllPinnedTabs(for: "Default").map { $0.guid }, ["default-pinned"])
        XCTAssertEqual(store.getAllPinnedTabs(for: "Work").map { $0.guid }, ["work-pinned"])
    }

    func testFetchBookmarksAndDeleteProtectionRespectProfileRoot() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(profileId: "Default")
        let workProfile = ProfileModel(profileId: "Work")
        context.insert(defaultProfile)
        context.insert(workProfile)

        let defaultRoot = makeFolder(guid: "root-default", title: "Bookmarks")
        defaultRoot.profile = defaultProfile
        defaultProfile.bookmarkRoot = defaultRoot
        context.insert(defaultRoot)

        let workRoot = makeFolder(guid: "root-work", title: "Bookmarks")
        workRoot.profile = workProfile
        workProfile.bookmarkRoot = workRoot
        context.insert(workRoot)

        let defaultBookmark = makeTab(guid: "bookmark-default", title: "Default Bookmark", url: "https://default.example")
        defaultBookmark.dataType = TabDataType.bookmark
        defaultBookmark.parent = defaultRoot
        defaultBookmark.profile = defaultProfile
        context.insert(defaultBookmark)

        let workBookmark = makeTab(guid: "bookmark-work", title: "Work Bookmark", url: "https://work.example")
        workBookmark.dataType = TabDataType.bookmark
        workBookmark.parent = workRoot
        workBookmark.profile = workProfile
        context.insert(workBookmark)

        try context.save()

        XCTAssertEqual(store.fetchBookmarks(parentId: nil as String?, profileId: "Default").map { $0.guid }, ["bookmark-default"])
        XCTAssertEqual(store.fetchBookmarks(parentId: nil as String?, profileId: "Work").map { $0.guid }, ["bookmark-work"])

        store.deleteBookmark("root-default", profileId: "Default")
        try waitForBackgroundWrite()

        let refreshedDefaultRoot: [TabDataModel] = try context.fetch(
            FetchDescriptor<TabDataModel>(predicate: #Predicate<TabDataModel> { $0.guid == "root-default" })
        )
        XCTAssertEqual(refreshedDefaultRoot.count, 1)
    }

    func testBrowserStateStoresProfileId() throws {
        let store = try makeStore()

        let state = BrowserState(windowId: 7, localStore: store, profileId: "Work")

        XCTAssertEqual(state.profileId, "Work")
    }

    func testBrowserStateRefreshesPersistedPinnedTabURLWhenLocalStoreChanges() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)

        let pinnedModel = makeTab(guid: "pinned-guid", title: "Pinned", url: "https://163.com")
        pinnedModel.dataType = TabDataType.pinnedTab
        pinnedModel.profile = profile
        context.insert(pinnedModel)
        try context.save()

        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        pinnedTab.isOpenned = true
        pinnedTab.url = "https://github.com/features/copilot"

        store.updateTabURL("pinned-guid", url: try XCTUnwrap(URL(string: "https://qq.com")))
        try waitUntil {
            pinnedTab.pinnedUrl == "https://qq.com"
        }

        XCTAssertTrue(
            state.pinnedTabs.first === pinnedTab,
            "BrowserState should keep the existing pinned tab runtime object so open state and wrapper bindings are preserved."
        )
        XCTAssertEqual(
            pinnedTab.pinnedUrl,
            "https://qq.com",
            "Persisted pinned-tab URL changes should refresh the in-memory pinnedUrl used when the tab is closed and reopened."
        )
        XCTAssertEqual(
            pinnedTab.url,
            "https://github.com/features/copilot",
            "Refreshing persisted pinned-tab metadata must not overwrite the currently opened page URL."
        )
    }

    func testBrowserStatePinnedTabEditingURLPrefersPersistedURLOverRuntimeNavigationURL() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)
        let pinnedModel = makeTab(guid: "github-pinned", title: "GitHub", url: "https://github.com")
        pinnedModel.dataType = TabDataType.pinnedTab
        pinnedModel.profile = profile
        context.insert(pinnedModel)
        try context.save()

        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        let pinnedTab = Tab(
            guid: 42,
            url: "https://github.com/features/copilot",
            isActive: true,
            index: 0,
            title: "GitHub Copilot",
            customGuid: "github-pinned"
        )
        pinnedTab.isPinned = true
        pinnedTab.pinnedUrl = "https://stale.example"
        state.pinnedTabs = [pinnedTab]

        let editingURL = state.pinnedTabEditingURL(
            for: "github-pinned",
            fallbackURL: "https://github.com/features/copilot"
        )

        XCTAssertEqual(
            editingURL,
            "https://github.com",
            "Editing a pinned tab should show the persisted URL instead of the currently navigated page URL."
        )
    }

    func testBrowserDataImporterStoresTargetContext() {
        let importer = BrowserDataImporter(targetProfileId: "Work", targetWindowId: 42)

        XCTAssertEqual(importer.targetProfileId, "Work")
        XCTAssertEqual(importer.targetWindowId, 42)
    }

    private func makeStore() throws -> LocalStore {
        let directory = try makeTemporaryStoreDirectory()
        return LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func seedLegacyStore(at directory: URL) throws {
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("LocalStore.sqlite"))
        let container = try ModelContainer(for: TabDataModelSchemaV2.TabDataModel.self, configurations: configuration)
        let context = container.mainContext

        let row = TabDataModelSchemaV2.TabDataModel(
            title: "Legacy Pinned",
            guid: "legacy-guid",
            index: 0,
            url: URL(string: "https://legacy.example")!,
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
        row.type = TabDataType.pinnedTab.rawValue
        row.profileId = "legacy-account"
        context.insert(row)
        try context.save()
    }

    private func makeFolder(guid: String, title: String) -> TabDataModel {
        let folder = TabDataModel(
            title: title,
            guid: guid,
            index: 0,
            url: URL(string: "https://bookmark.phi/folder")!,
            favicon: nil as Data?,
            createdDate: Date(),
            updatedDate: Date()
        )
        folder.dataType = TabDataType.bookmarkFolder
        return folder
    }

    private func makeTab(guid: String, title: String, url: String) -> TabDataModel {
        TabDataModel(
            title: title,
            guid: guid,
            index: 0,
            url: URL(string: url)!,
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
    }

    private func waitForBackgroundWrite() throws {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func waitUntil(timeout: TimeInterval = 1, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition was not met before timeout.")
    }
}
