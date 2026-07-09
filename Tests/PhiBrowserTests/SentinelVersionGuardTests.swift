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

    func testConvergenceStopsOnceSentinelAdoptsExpectedVersion() async {
        // Sentinel reports the old version at evaluation, then the expected version on
        // the first confirmation read: only the initial request should be posted.
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            sentinelVersions: ["1.2.0", "1.2.1"],
            maxRetries: 3
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(postedSnapshots.count, 1)
    }

    func testConvergenceRepostsUntilRetriesExhausted() async {
        // Sentinel never adopts the expected version: initial post + one re-post per retry.
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            sentinelVersions: ["1.2.0"],
            maxRetries: 2
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(postedSnapshots.count, 3)
    }

    func testConvergenceStopsWhenSentinelStopsReporting() async {
        // If Sentinel is no longer reporting a version, stop confirming (nothing to converge).
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            sentinelVersions: ["1.2.0", nil],
            maxRetries: 3
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(postedSnapshots.count, 1)
    }

    private func makeConvergenceGuard(
        browserVersion: String,
        sentinelVersions: [String?],
        maxRetries: Int
    ) -> SentinelVersionGuard {
        var callIndex = 0
        return SentinelVersionGuard(
            userDefaults: defaults,
            now: { self.now },
            browserBundleIDProvider: { "com.phibrowser.Mac" },
            browserVersionProvider: { browserVersion },
            sentinelInfoProvider: { sentinelBundleID in
                let version = sentinelVersions[min(callIndex, sentinelVersions.count - 1)]
                callIndex += 1
                guard let version else { return nil }
                return SentinelVersionGuard.RunningSentinelInfo(
                    bundleID: sentinelBundleID,
                    version: version
                )
            },
            restartRequestPoster: { snapshot, _ in
                self.postedSnapshots.append(snapshot)
            },
            sentinelLauncher: {
                self.launchCount += 1
            },
            logger: { _ in },
            sleep: { _ in },
            confirmInterval: 0,
            maxConfirmationRetries: maxRetries
        )
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
