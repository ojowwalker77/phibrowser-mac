// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CocoaLumberjackSwift
import Foundation

struct SentinelVersionGuardSnapshot: Equatable {
    let browserBundleID: String
    let browserVersion: String
    let sentinelBundleID: String
    let sentinelVersion: String

    var mismatchKey: String {
        [
            browserBundleID,
            sentinelBundleID,
            browserVersion,
            sentinelVersion
        ].joined(separator: "|")
    }
}

enum SentinelVersionGuardDecision: Equatable {
    case skip(String)
    case launchSentinel
    case requestRestart(SentinelVersionGuardSnapshot)
}

final class SentinelVersionGuard {
    static let shared = SentinelVersionGuard()

    static let restartRequestNotification = Notification.Name("com.phibrowser.sentinel.restart.request")

    private static let stableBrowserBundleID = "com.phibrowser.Mac"
    private static let stableSentinelBundleID = "com.phibrowser.Sentinel"
    private static let canarySentinelBundleID = "com.phibrowser.canary.Sentinel"
    private static let devSentinelBundleID = "com.phibrowser.dev.Sentinel"

    private let userDefaults: UserDefaults
    private let cooldown: TimeInterval
    private let now: () -> Date
    private let browserBundleIDProvider: () -> String
    private let browserVersionProvider: () -> String
    private let sentinelInfoProvider: (String) -> RunningSentinelInfo?
    private let restartRequestPoster: (SentinelVersionGuardSnapshot, String) -> Void
    private let sentinelLauncher: () -> Void
    private let logger: (String) -> Void
    private let sleep: (TimeInterval) async -> Void
    /// Seconds to wait between confirming whether Sentinel adopted the expected version.
    private let confirmInterval: TimeInterval
    /// Maximum number of confirm-and-re-post cycles before giving up on convergence.
    /// The total budget (interval × retries) must cover Sentinel's worst-case relaunch:
    /// its runner stop allows a 45s SIGTERM grace before the new instance comes up, so
    /// a short budget would emit false "did not converge" warnings on healthy relaunches.
    private let maxConfirmationRetries: Int

    private let lastMismatchKeyDefaultsKey = "SentinelVersionGuard.lastMismatchKey"
    private let lastAttemptTimestampDefaultsKey = "SentinelVersionGuard.lastAttemptTimestamp"

    struct RunningSentinelInfo {
        let bundleID: String
        let version: String?
    }

    init(
        userDefaults: UserDefaults = .standard,
        cooldown: TimeInterval = 10 * 60,
        now: @escaping () -> Date = Date.init,
        browserBundleIDProvider: @escaping () -> String = {
            Bundle.main.bundleIdentifier ?? ""
        },
        browserVersionProvider: @escaping () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        },
        sentinelInfoProvider: @escaping (String) -> RunningSentinelInfo? = SentinelVersionGuard.defaultRunningSentinelInfo,
        restartRequestPoster: @escaping (SentinelVersionGuardSnapshot, String) -> Void = SentinelVersionGuard.postRestartRequest,
        sentinelLauncher: @escaping () -> Void = SentinelHelper.launch,
        logger: @escaping (String) -> Void = { AppLogInfo("[SentinelVersionGuard] \($0)") },
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        },
        confirmInterval: TimeInterval = 5,
        maxConfirmationRetries: Int = 10
    ) {
        self.userDefaults = userDefaults
        self.cooldown = cooldown
        self.now = now
        self.browserBundleIDProvider = browserBundleIDProvider
        self.browserVersionProvider = browserVersionProvider
        self.sentinelInfoProvider = sentinelInfoProvider
        self.restartRequestPoster = restartRequestPoster
        self.sentinelLauncher = sentinelLauncher
        self.logger = logger
        self.sleep = sleep
        self.confirmInterval = confirmInterval
        self.maxConfirmationRetries = maxConfirmationRetries
    }

    func runStartupCheck(delaySeconds: TimeInterval = 3) async {
        if delaySeconds > 0 {
            await sleep(delaySeconds)
        }

        let decision = evaluateCurrentState()
        apply(decision)

        // A single restart request is not enough. It can be missed entirely (Sentinel
        // registers its restart observer late, during its own cold launch) or Sentinel
        // may simply not have relaunched yet. Confirm the running Sentinel actually
        // adopts the expected version, re-posting a bounded number of times until it
        // converges — otherwise the browser and Sentinel can stay on mismatched versions.
        guard case .requestRestart(let snapshot) = decision else { return }
        await confirmConvergence(snapshot)
    }

    /// After a restart request, waits for the running Sentinel to report the expected
    /// version. Re-posts the request on each unconverged check, up to
    /// `maxConfirmationRetries` times, then logs a warning if convergence never happened.
    ///
    /// Two distinct "no version" states must not be conflated (`SentinelHelper.runningInfo`):
    /// a `nil` info means the *process is gone* — nothing will bring Sentinel back until
    /// the next browser launch, so launch it (mirroring `evaluateCurrentState`'s
    /// `.launchSentinel`); an info with a `nil`/empty version means the process is up but
    /// has not (re)written its runtime-info file yet — the expected transient window in
    /// the middle of a self-relaunch, so keep waiting.
    private func confirmConvergence(_ snapshot: SentinelVersionGuardSnapshot) async {
        for attempt in 1...maxConfirmationRetries {
            await sleep(confirmInterval)

            guard let info = sentinelInfoProvider(snapshot.sentinelBundleID) else {
                // Process gone (relaunch failed, or it exited and nothing respawned it).
                // Launching a duplicate is safe: Sentinel's single-instance guard makes
                // the loser abort, and ensureRunning no-ops if it is already back up.
                logger("convergence check: Sentinel is not running; launching it")
                sentinelLauncher()
                return
            }

            guard let running = info.version, !running.isEmpty else {
                logger("convergence check: Sentinel running but not reporting a version yet (\(attempt)/\(maxConfirmationRetries))")
                continue
            }

            if running == snapshot.browserVersion {
                logger("convergence check: Sentinel converged to \(running) after \(attempt) check(s)")
                return
            }

            logger("convergence check: Sentinel still \(running), expected \(snapshot.browserVersion); re-posting restart (\(attempt)/\(maxConfirmationRetries))")
            restartRequestPoster(snapshot, UUID().uuidString)
        }

        logger("convergence check: WARNING Sentinel did not converge to \(snapshot.browserVersion) after \(maxConfirmationRetries) retries")
    }

    func evaluateCurrentState() -> SentinelVersionGuardDecision {
        let browserBundleID = browserBundleIDProvider()
        let browserVersion = browserVersionProvider()

        guard browserBundleID == Self.stableBrowserBundleID else {
            return .skip("strict version check disabled for browser bundle \(browserBundleID)")
        }

        guard !browserVersion.isEmpty else {
            return .skip("browser version unavailable")
        }

        guard let sentinelBundleID = expectedSentinelBundleID(forBrowserBundleID: browserBundleID) else {
            return .skip("no Sentinel bundle mapping for browser bundle \(browserBundleID)")
        }

        guard let sentinelInfo = sentinelInfoProvider(sentinelBundleID) else {
            return .launchSentinel
        }

        guard sentinelInfo.bundleID == sentinelBundleID else {
            return .skip("running Sentinel bundle mismatch: \(sentinelInfo.bundleID)")
        }

        guard let sentinelVersion = sentinelInfo.version, !sentinelVersion.isEmpty else {
            return .skip("Sentinel version unavailable")
        }

        let snapshot = SentinelVersionGuardSnapshot(
            browserBundleID: browserBundleID,
            browserVersion: browserVersion,
            sentinelBundleID: sentinelBundleID,
            sentinelVersion: sentinelVersion
        )

        guard browserVersion != sentinelVersion else {
            return .skip("versions match: \(browserVersion)")
        }

        guard shouldAttemptRestart(for: snapshot.mismatchKey) else {
            return .skip("restart suppressed by cooldown for \(snapshot.mismatchKey)")
        }

        return .requestRestart(snapshot)
    }

    func apply(_ decision: SentinelVersionGuardDecision) {
        switch decision {
        case .skip(let reason):
            logger("skip: \(reason)")
        case .launchSentinel:
            logger("Sentinel is not running; launching without restart request")
            sentinelLauncher()
        case .requestRestart(let snapshot):
            recordRestartAttempt(for: snapshot.mismatchKey)
            let requestID = UUID().uuidString
            logger(
                "requesting Sentinel restart requestID=\(requestID) browser=\(snapshot.browserVersion) sentinel=\(snapshot.sentinelVersion)"
            )
            restartRequestPoster(snapshot, requestID)
        }
    }

    private func shouldAttemptRestart(for mismatchKey: String) -> Bool {
        let lastKey = userDefaults.string(forKey: lastMismatchKeyDefaultsKey)
        let lastTimestamp = userDefaults.double(forKey: lastAttemptTimestampDefaultsKey)

        guard lastKey == mismatchKey, lastTimestamp > 0 else {
            return true
        }

        return now().timeIntervalSince1970 - lastTimestamp >= cooldown
    }

    private func recordRestartAttempt(for mismatchKey: String) {
        userDefaults.set(mismatchKey, forKey: lastMismatchKeyDefaultsKey)
        userDefaults.set(now().timeIntervalSince1970, forKey: lastAttemptTimestampDefaultsKey)
    }

    private func expectedSentinelBundleID(forBrowserBundleID bundleID: String) -> String? {
        let lowercased = bundleID.lowercased()
        if lowercased == Self.stableBrowserBundleID.lowercased() {
            return Self.stableSentinelBundleID
        }
        if lowercased.contains(".canary.") {
            return Self.canarySentinelBundleID
        }
        if lowercased.contains(".dev.") {
            return Self.devSentinelBundleID
        }
        return nil
    }

    private static func defaultRunningSentinelInfo(sentinelBundleID: String) -> RunningSentinelInfo? {
        guard let info = SentinelHelper.runningInfo(identifier: sentinelBundleID) else {
            return nil
        }

        return RunningSentinelInfo(
            bundleID: info.bundleID,
            version: info.version
        )
    }

    private static func postRestartRequest(snapshot: SentinelVersionGuardSnapshot, requestID: String) {
        DistributedNotificationCenter.default().postNotificationName(
            restartRequestNotification,
            object: snapshot.sentinelBundleID,
            userInfo: [
                "expectedVersion": snapshot.browserVersion,
                "browserBundleID": snapshot.browserBundleID,
                "reason": "browser_version_mismatch",
                "requestID": requestID
            ],
            deliverImmediately: true
        )
    }
}
