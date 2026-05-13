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
        logger: @escaping (String) -> Void = { AppLogInfo("[SentinelVersionGuard] \($0)") }
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
    }

    func runStartupCheck(delaySeconds: TimeInterval = 3) async {
        if delaySeconds > 0 {
            let nanoseconds = UInt64(delaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }

        let decision = evaluateCurrentState()
        apply(decision)
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
        guard let app = NSWorkspace.shared.runningApplications.first(where: { runningApp in
            guard let bundleID = runningApp.bundleIdentifier else { return false }
            return bundleID.caseInsensitiveCompare(sentinelBundleID) == .orderedSame && !runningApp.isTerminated
        }) else {
            return nil
        }

        return RunningSentinelInfo(
            bundleID: app.bundleIdentifier ?? sentinelBundleID,
            version: readVersion(from: app.bundleURL)
        )
    }

    private static func readVersion(from bundleURL: URL?) -> String? {
        guard let infoPlistURL = bundleURL?
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false),
              let info = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else {
            return nil
        }

        return info["CFBundleShortVersionString"] as? String
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
