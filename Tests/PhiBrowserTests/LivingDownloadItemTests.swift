// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import XCTest
@testable import Phi

final class LivingDownloadItemTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Risky downloads must never arm auto-dismiss when download completes while unsafe.
    func testWarningItemDoesNotAutoDismissAfterHoverEnds() {
        let item = DownloadItem(
            id: "warning-download",
            fileName: "dangerous.pkg",
            url: "https://example.com/dangerous.pkg",
            state: .complete,
            percentComplete: 100,
            totalBytes: 1024,
            receivedBytes: 1024
        )
        item.isDangerous = true
        item.dangerType = DownloadDangerType.dangerousFile.rawValue
        item.isInsecure = false
        item.insecureDownloadStatus = InsecureDownloadStatus.safe.rawValue

        let livingItem = LivingDownloadItem(downloadItem: item, dismissDuration: 0.05)

        let mustNotDismiss = expectation(description: "Warning item must not set shouldDismiss")
        mustNotDismiss.isInverted = true
        livingItem.$shouldDismiss
            .dropFirst()
            .filter(\.self)
            .sink { _ in mustNotDismiss.fulfill() }
            .store(in: &cancellables)

        livingItem.setHovered(true)
        livingItem.setHovered(false)

        wait(for: [mustNotDismiss], timeout: 2.0)
        XCTAssertFalse(livingItem.shouldDismiss)
    }

    func testNormalItemDismissTimerIsNotResetByUnchangedSafetyFields() {
        let item = DownloadItem(
            id: "normal-download",
            fileName: "safe.zip",
            url: "https://example.com/safe.zip",
            state: .complete,
            percentComplete: 100,
            totalBytes: 1024,
            receivedBytes: 1024
        )
        item.isDangerous = false
        item.dangerType = DownloadDangerType.notDangerous.rawValue
        item.isInsecure = false
        item.insecureDownloadStatus = InsecureDownloadStatus.safe.rawValue

        let dismissDuration = 0.35
        let livingItem = LivingDownloadItem(downloadItem: item, dismissDuration: dismissDuration)

        let didDismiss = expectation(description: "Safe item dismisses once timer elapses")

        livingItem.$shouldDismiss
            .dropFirst()
            .filter(\.self)
            .sink { _ in didDismiss.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Same value write should not reset dismiss timer.
            item.isDangerous = false
        }

        wait(for: [didDismiss], timeout: max(dismissDuration + 2.0, 5.0))
    }
}
