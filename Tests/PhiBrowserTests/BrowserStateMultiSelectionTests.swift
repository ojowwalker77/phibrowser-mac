// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class BrowserStateMultiSelectionTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(!TabMultiSelection.isEnabled, "Tab multi-selection is disabled.")
    }

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func seed(_ state: BrowserState, guids: [Int]) {
        state.tabs = guids.map { Tab(guid: $0, url: "https://e\($0).example", isActive: false, index: 0) }
        state.updateNormalTabs()
    }

    func testToggleNormalTabEntersAndExits() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[1])
        XCTAssertTrue(state.multiSelection.isActive)
        XCTAssertEqual(state.multiSelection.guids, [2])

        state.toggleMultiSelection(for: state.tabs[1])
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testToggleActiveTabIsNoop() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleMultiSelection(for: state.tabs[0])
        XCTAssertEqual(state.multiSelection.guids, [2])
    }

    func testClearMultiSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleMultiSelection(for: state.tabs[2])
        XCTAssertTrue(state.multiSelection.isActive)

        state.clearMultiSelection()
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testOrderedSelectionFollowsTabOrderNotClickOrder() throws {
        let state = try makeState()
        seed(state, guids: [10, 20, 30, 40])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[2]) // 30
        state.toggleMultiSelection(for: state.tabs[1]) // 20
        XCTAssertEqual(state.orderedMultiSelectedTabs.map(\.guid), [10, 20, 30])
    }

    func testPinnedTabToggleClearsSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[1])
        let pinned = Tab(guid: 99, url: "https://pinned.example", isActive: false, index: 0)
        pinned.isPinned = true
        state.toggleMultiSelection(for: pinned)
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testAddToGroupDedupsTabsAlreadyInThatGroup() throws {
        let state = try makeState()
        state.tabs = [
            Tab(guid: 1, url: "https://1", isActive: false, index: 0),
            Tab(guid: 2, url: "https://2", isActive: false, index: 0),
            Tab(guid: 3, url: "https://3", isActive: false, index: 0),
        ]
        state.tabs[1].groupToken = "A"
        state.updateNormalTabs()
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleMultiSelection(for: state.tabs[2])
        let targets = state.multiSelectionTargets(forAddingToGroup: "A")
        XCTAssertEqual(targets.map(\.guid), [1, 3])
    }

    func testClosingSelectedTabPrunesSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleMultiSelection(for: state.tabs[2])
        XCTAssertEqual(state.multiSelection.guids, [2, 3])

        state.tabs.removeAll { $0.guid == 2 }
        state.updateNormalTabs()

        XCTAssertEqual(state.multiSelection.guids, [3])
    }
}
