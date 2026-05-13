// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelVersionGuardTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var now: Date!
    private var postedSnapshots: [SentinelVersionGuardSnapshot]!
    private var launchCount: Int!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "SentinelVersionGuardTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        now = Date(timeIntervalSince1970: 1_778_620_000)
        postedSnapshots = []
        launchCount = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        now = nil
        postedSnapshots = nil
        launchCount = nil
        super.tearDown()
    }

    func testStableMatchingVersionsSkipsRestart() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: "1.2.1"
        )

        let decision = guarder.evaluateCurrentState()
        guarder.apply(decision)

        XCTAssertEqual(postedSnapshots.count, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testStableMismatchRequestsRestart() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: "1.2.0"
        )

        let decision = guarder.evaluateCurrentState()
        guarder.apply(decision)

        XCTAssertEqual(postedSnapshots.count, 1)
        XCTAssertEqual(postedSnapshots.first?.browserVersion, "1.2.1")
        XCTAssertEqual(postedSnapshots.first?.sentinelVersion, "1.2.0")
        XCTAssertEqual(launchCount, 0)
    }

    func testSameStableMismatchWithinCooldownDoesNotRestartAgain() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: "1.2.0"
        )

        let firstDecision = guarder.evaluateCurrentState()
        guarder.apply(firstDecision)
        now = now.addingTimeInterval(60)
        let secondDecision = guarder.evaluateCurrentState()
        guarder.apply(secondDecision)

        XCTAssertEqual(postedSnapshots.count, 1)
    }

    func testSameStableMismatchAfterCooldownCanRestartAgain() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: "1.2.0"
        )

        guarder.apply(guarder.evaluateCurrentState())
        now = now.addingTimeInterval(11 * 60)
        guarder.apply(guarder.evaluateCurrentState())

        XCTAssertEqual(postedSnapshots.count, 2)
    }

    func testCanaryMismatchSkipsRestart() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.canary.Mac",
            browserVersion: "Canary",
            sentinelVersion: "2026.05.11.bc3653c2"
        )

        guarder.apply(guarder.evaluateCurrentState())

        XCTAssertEqual(postedSnapshots.count, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testDevMismatchSkipsRestart() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.dev.Mac",
            browserVersion: "dev",
            sentinelVersion: "2026.05.13.120000"
        )

        guarder.apply(guarder.evaluateCurrentState())

        XCTAssertEqual(postedSnapshots.count, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testStableSentinelNotRunningLaunchesWithoutRestartRequest() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: nil
        )

        guarder.apply(guarder.evaluateCurrentState())

        XCTAssertEqual(postedSnapshots.count, 0)
        XCTAssertEqual(launchCount, 1)
    }

    private func makeGuard(
        browserBundleID: String,
        browserVersion: String,
        sentinelVersion: String?
    ) -> SentinelVersionGuard {
        SentinelVersionGuard(
            userDefaults: defaults,
            now: { self.now },
            browserBundleIDProvider: { browserBundleID },
            browserVersionProvider: { browserVersion },
            sentinelInfoProvider: { sentinelBundleID in
                guard let sentinelVersion else { return nil }
                return SentinelVersionGuard.RunningSentinelInfo(
                    bundleID: sentinelBundleID,
                    version: sentinelVersion
                )
            },
            restartRequestPoster: { snapshot, _ in
                self.postedSnapshots.append(snapshot)
            },
            sentinelLauncher: {
                self.launchCount += 1
            },
            logger: { _ in }
        )
    }
}
