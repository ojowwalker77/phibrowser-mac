// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AccountUserDefaultsTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        storeURL = temporaryDirectory.appendingPathComponent("account_defaults.plist")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCoalescedSidebarWritesStayInMemoryUntilFlush() throws {
        let defaults = makeDefaults(coalescingDelay: 60)

        defaults.setLastKnownSidebarWidth(220)
        defaults.setLastKnownSidebarWidth(260)

        XCTAssertEqual(defaults.lastKnownSidebarWidth, 260)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))

        defaults.flush()

        XCTAssertEqual(try persistedDouble(for: .lastKnownSidebarWidth), 260)
    }

    func testImmediateWriteFlushesPendingGeometryWithLatestState() throws {
        let defaults = makeDefaults(coalescingDelay: 60)

        defaults.setLastKnownSidebarWidth(310)
        defaults.set("popup", forKey: AccountUserDefaults.DefaultsKey.notificationPopupMode)

        XCTAssertEqual(try persistedDouble(for: .lastKnownSidebarWidth), 310)
        XCTAssertEqual(try persistedStore()[AccountUserDefaults.DefaultsKey.notificationPopupMode.rawValue] as? String, "popup")
    }

    func testCoalescedWritePersistsAfterDelay() throws {
        let defaults = makeDefaults(coalescingDelay: 0.02)
        let persisted = expectation(description: "coalesced write persisted")

        defaults.setLastKnownSidebarWidth(275)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            if FileManager.default.fileExists(atPath: self.storeURL.path) {
                persisted.fulfill()
            }
        }

        wait(for: [persisted], timeout: 1)
        XCTAssertEqual(try persistedDouble(for: .lastKnownSidebarWidth), 275)
    }

    private func makeDefaults(coalescingDelay: TimeInterval) -> AccountUserDefaults {
        AccountUserDefaults(
            account: Account(userID: UUID().uuidString),
            storeURL: storeURL,
            coalescingDelay: coalescingDelay
        )
    }

    private func persistedDouble(for key: AccountUserDefaults.DefaultsKey) throws -> Double? {
        try persistedStore()[key.rawValue] as? Double
    }

    private func persistedStore() throws -> [String: Any] {
        let data = try Data(contentsOf: storeURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(propertyList as? [String: Any])
    }
}
