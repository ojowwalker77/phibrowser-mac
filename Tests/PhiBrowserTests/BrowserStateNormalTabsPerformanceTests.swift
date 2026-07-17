// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import XCTest
@testable import Phi

@MainActor
final class BrowserStateNormalTabsPerformanceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testNoOpRebuildDoesNotRepublishNormalTabs() throws {
        let state = try makeState()
        state.tabs = makeTabs(count: 100)
        state.updateNormalTabs()

        var publicationCount = 0
        let subscription = state.$normalTabs.dropFirst().sink { _ in
            publicationCount += 1
        }

        state.updateNormalTabs()

        XCTAssertEqual(publicationCount, 0)
        _ = subscription
    }

    func testLargeRebuildKeepsStableOrderAndSplitAdjacency() throws {
        let state = try makeState()
        state.tabs = makeTabs(count: 1_000)
        state.splits = [
            SplitGroup(
                id: "split-10-900",
                primaryTabId: 10,
                secondaryTabId: 900,
                layout: .vertical,
                ratio: 0.5
            )
        ]

        state.updateNormalTabs()

        XCTAssertEqual(state.normalTabs.count, 1_000)
        let primaryIndex = try XCTUnwrap(state.normalTabs.firstIndex { $0.guid == 10 })
        XCTAssertEqual(state.normalTabs[primaryIndex + 1].guid, 900)
        XCTAssertEqual(Set(state.normalTabs.map(\.guid)).count, 1_000)
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory
        )
        return BrowserState(windowId: 33, localStore: store, profileId: "Default")
    }

    private func makeTabs(count: Int) -> [Tab] {
        (0..<count).map { index in
            Tab(
                guid: index + 1,
                url: "https://example.com/\(index)",
                isActive: index == 0,
                index: index
            )
        }
    }
}
