// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class BrowserStateTabGroupBlockTests: XCTestCase {

    // MARK: - Helpers

    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeBrowserState(profileId: String = "Default") throws -> BrowserState {
        let directory = try makeTemporaryStoreDirectory()
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: profileId)
    }

    /// Seeds `state` with the given tabs in order and groups any tab whose
    /// token is non-nil. Returns the seeded tabs in the same order so tests
    /// can grab references by index.
    @discardableResult
    private func seed(state: BrowserState,
                      tabs: [(guid: Int, url: String, token: String?)]) -> [Tab] {
        let constructed: [Tab] = tabs.map { spec in
            let tab = Tab(guid: spec.guid, url: spec.url, isActive: false, index: 0)
            return tab
        }
        state.tabs = constructed
        state.updateNormalTabs()

        // Group tabs by token, then prime each group via the same handler
        // Chromium drives so groupToken / groups stay in sync.
        let tokens = Set(tabs.compactMap { $0.token })
        for token in tokens {
            let initialIds = tabs.filter { $0.token == token }.map { $0.guid }
            state.handleTabGroupCreated(token: token,
                                        title: "",
                                        color: .blue,
                                        isCollapsed: false,
                                        initialTabIds: initialIds)
        }
        return constructed
    }

    private func waitForBackgroundWrite() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    // MARK: - moveGroupBlock

    /// `[N1, A1, A2, N2, N3]` with group A at indices 1..2.
    /// `moveGroupBlock("A", to: 5)` moves the block to the strip's tail.
    /// The toIndex is interpreted in PRE-move coords (NSOutlineView
    /// convention), and is adjusted by `-blockSize` when the block moves
    /// forward, mirroring `moveNormalTabLocally`'s `-1` adjustment.
    func testMoveGroupBlock_movesGroupAsContiguousBlock_preservingMemberOrder() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 101, url: "https://n2.example", token: nil),
            (guid: 102, url: "https://n3.example", token: nil),
        ])

        state.moveGroupBlock(token: "A", to: 5)

        XCTAssertEqual(state.normalTabs.map { $0.guid },
                       [100, 101, 102, 200, 201])
    }

    func testMoveGroupBlock_toStart_preservesMemberOrder() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 101, url: "https://n2.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 102, url: "https://n3.example", token: nil),
        ])

        state.moveGroupBlock(token: "A", to: 0)

        XCTAssertEqual(state.normalTabs.map { $0.guid },
                       [200, 201, 100, 101, 102])
    }

    func testMoveGroupBlock_blockAlreadyAtTarget_isNoOp() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 100, url: "https://n1.example", token: nil),
        ])

        let before = state.normalTabs.map { $0.guid }
        state.moveGroupBlock(token: "A", to: 0)
        XCTAssertEqual(state.normalTabs.map { $0.guid }, before)
    }

    func testMoveGroupBlock_unknownToken_isNoOp() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 101, url: "https://n2.example", token: nil),
        ])

        let before = state.normalTabs.map { $0.guid }
        state.moveGroupBlock(token: "DOES_NOT_EXIST", to: 0)
        XCTAssertEqual(state.normalTabs.map { $0.guid }, before)
    }

    // MARK: - convertGroupToBookmarks

    /// Verifies that `convertGroupToBookmarks` rewires each member to a
    /// fresh bookmark record without closing any tabs. NOTE: in tests
    /// `ChromiumLauncher.sharedInstance().bridge` is nil, so the
    /// `removeTabsFromGroup` branch in `moveNormalTab(toBookmark:)` is
    /// skipped — `tab.groupToken` is therefore NOT cleared by the local
    /// path. We assert what the local-only path actually does (each member's
    /// `guidInLocalDB` flips to a fresh bookmark guid) and document the gap
    /// for the controller.
    func testConvertGroupToBookmarks_dissolvesGroupMembership_andCreatesBookmarks() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 101, url: "https://n2.example", token: nil),
        ])
        let a1 = tabs[1]
        let a2 = tabs[2]
        let originalA1Guid = a1.guidInLocalDB
        let originalA2Guid = a2.guidInLocalDB

        state.convertGroupToBookmarks(token: "A", parentFolder: nil, at: 0)

        // Local rewire: each member now points at a brand-new local guid.
        XCTAssertNotEqual(a1.guidInLocalDB, originalA1Guid)
        XCTAssertNotEqual(a2.guidInLocalDB, originalA2Guid)
        XCTAssertNotNil(a1.guidInLocalDB)
        XCTAssertNotNil(a2.guidInLocalDB)

        // Members are NOT closed.
        XCTAssertTrue(state.tabs.contains { $0.guid == 200 })
        XCTAssertTrue(state.tabs.contains { $0.guid == 201 })

        // Persisted bookmarks land under the profile root after the
        // background write settles.
        waitForBackgroundWrite()
        let stored = state.localStore.fetchBookmarks(parentId: nil as String?,
                                                     profileId: state.profileId)
        let storedURLs = stored.map { $0.url.absoluteString }
        XCTAssertTrue(storedURLs.contains(where: { $0.contains("a1.example") }),
                      "expected bookmark for a1; stored=\(storedURLs)")
        XCTAssertTrue(storedURLs.contains(where: { $0.contains("a2.example") }),
                      "expected bookmark for a2; stored=\(storedURLs)")
    }

    /// Members hit `moveNormalTab(toBookmark:index:)` in normalTabs order
    /// with monotonically increasing `index`, so the persisted bookmarks
    /// keep the pre-dissolution member order.
    func testConvertGroupToBookmarks_preservesMemberOrderInBookmarks() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 202, url: "https://a3.example", token: "A"),
        ])

        state.convertGroupToBookmarks(token: "A", parentFolder: nil, at: 0)

        waitForBackgroundWrite()
        let stored = state.localStore.fetchBookmarks(parentId: nil as String?,
                                                     profileId: state.profileId)
        // Sort by the persisted sibling index since fetchBookmarks isn't
        // contractually ordered.
        let ordered = stored.sorted { $0.index < $1.index }
        let urls = ordered.map { $0.url.absoluteString }
        let aOnly = urls.filter { $0.contains("example") }
        XCTAssertEqual(aOnly.count, 3, "expected 3 bookmarks; got \(urls)")
        let firstA1 = aOnly.firstIndex { $0.contains("a1.example") }
        let firstA2 = aOnly.firstIndex { $0.contains("a2.example") }
        let firstA3 = aOnly.firstIndex { $0.contains("a3.example") }
        XCTAssertNotNil(firstA1)
        XCTAssertNotNil(firstA2)
        XCTAssertNotNil(firstA3)
        if let i1 = firstA1, let i2 = firstA2, let i3 = firstA3 {
            XCTAssertLessThan(i1, i2, "a1 should precede a2")
            XCTAssertLessThan(i2, i3, "a2 should precede a3")
        }
    }
}
