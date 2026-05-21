// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog

struct ExperimentFlagEvaluation {
    let variant: String?
    let payload: Any?
}

struct ExperimentTimeoutConfig {
    let featureFlagKey: String
    let payloadKey: String
    let defaultMilliseconds: Int
    let allowedRange: ClosedRange<Int>

    init(
        featureFlagKey: String,
        payloadKey: String = "timeout_ms",
        defaultMilliseconds: Int,
        allowedRange: ClosedRange<Int>
    ) {
        self.featureFlagKey = featureFlagKey
        self.payloadKey = payloadKey
        self.defaultMilliseconds = defaultMilliseconds
        self.allowedRange = allowedRange
    }
}

struct Auth0RefreshExperimentConfig {
    let featureFlagKey: String
    let checkIntervalPayloadKey: String
    let urgentWindowPayloadKey: String
    let defaultCheckIntervalSeconds: Int
    let defaultUrgentWindowSeconds: Int
    let allowedCheckIntervalSeconds: ClosedRange<Int>
    let allowedUrgentWindowSeconds: ClosedRange<Int>

    init(
        featureFlagKey: String,
        checkIntervalPayloadKey: String = "refresh_check_interval_seconds",
        urgentWindowPayloadKey: String = "refresh_urgent_window_seconds",
        defaultCheckIntervalSeconds: Int,
        defaultUrgentWindowSeconds: Int,
        allowedCheckIntervalSeconds: ClosedRange<Int>,
        allowedUrgentWindowSeconds: ClosedRange<Int>
    ) {
        self.featureFlagKey = featureFlagKey
        self.checkIntervalPayloadKey = checkIntervalPayloadKey
        self.urgentWindowPayloadKey = urgentWindowPayloadKey
        self.defaultCheckIntervalSeconds = defaultCheckIntervalSeconds
        self.defaultUrgentWindowSeconds = defaultUrgentWindowSeconds
        self.allowedCheckIntervalSeconds = allowedCheckIntervalSeconds
        self.allowedUrgentWindowSeconds = allowedUrgentWindowSeconds
    }
}

extension ExperimentTimeoutConfig {
    static let requestTimeoutExperiment = ExperimentTimeoutConfig(
        featureFlagKey: "request-timeout-experiment",
        defaultMilliseconds: 5_000,
        allowedRange: 1_000...30_000
    )
}

extension Auth0RefreshExperimentConfig {
    static let auth0RefreshTimingExperiment = Auth0RefreshExperimentConfig(
        featureFlagKey: "auth0-refresh-timing",
        defaultCheckIntervalSeconds: 3_600,
        defaultUrgentWindowSeconds: 3_600,
        allowedCheckIntervalSeconds: 300...86_400,
        allowedUrgentWindowSeconds: 300...604_800
    )
}

struct ResolvedExperimentTimeout {
    let milliseconds: Int
    let variant: String?
    let featureFlagKey: String

    var featureProperties: [String: Any] {
        guard let variant else {
            return [:]
        }
        return ["$feature/\(featureFlagKey)": variant]
    }
}

struct ResolvedAuth0RefreshConfig {
    let checkInterval: Int
    let urgentWindow: Int
    let variant: String?
    let featureFlagKey: String

    var featureProperties: [String: Any] {
        guard let variant else {
            return [:]
        }
        return ["$feature/\(featureFlagKey)": variant]
    }
}

struct ExperimentConfigProvider {
    private let evaluateFlag: (String) -> ExperimentFlagEvaluation?

    init(_ evaluateFlag: @escaping (String) -> ExperimentFlagEvaluation?) {
        self.evaluateFlag = evaluateFlag
    }

    func resolveTimeout(_ config: ExperimentTimeoutConfig) -> ResolvedExperimentTimeout {
        let evaluation = evaluateFlag(config.featureFlagKey)
        let milliseconds = Self.clampedMilliseconds(
            Self.timeoutMilliseconds(from: evaluation?.payload, payloadKey: config.payloadKey) ?? config.defaultMilliseconds,
            allowedRange: config.allowedRange
        )

        return ResolvedExperimentTimeout(
            milliseconds: milliseconds,
            variant: evaluation?.variant,
            featureFlagKey: config.featureFlagKey
        )
    }

    func resolveAuth0RefreshConfig(_ config: Auth0RefreshExperimentConfig) -> ResolvedAuth0RefreshConfig {
        let evaluation = evaluateFlag(config.featureFlagKey)
        let checkInterval = Self.clampedValue(
            Self.integerValue(from: evaluation?.payload, payloadKey: config.checkIntervalPayloadKey) ?? config.defaultCheckIntervalSeconds,
            allowedRange: config.allowedCheckIntervalSeconds
        )
        let urgentWindow = Self.clampedValue(
            Self.integerValue(from: evaluation?.payload, payloadKey: config.urgentWindowPayloadKey) ?? config.defaultUrgentWindowSeconds,
            allowedRange: config.allowedUrgentWindowSeconds
        )

        return ResolvedAuth0RefreshConfig(
            checkInterval: checkInterval,
            urgentWindow: urgentWindow,
            variant: evaluation?.variant,
            featureFlagKey: config.featureFlagKey
        )
    }

    private static func timeoutMilliseconds(from payload: Any?, payloadKey: String) -> Int? {
        integerValue(from: payload, payloadKey: payloadKey)
    }

    private static func integerValue(from payload: Any?, payloadKey: String) -> Int? {
        guard let payload else {
            return nil
        }

        if let dictionary = payload as? [String: Any] {
            return integerValue(from: dictionary[payloadKey])
        }
        if let dictionary = payload as? NSDictionary {
            return integerValue(from: dictionary[payloadKey])
        }
        return integerValue(from: payload)
    }

    private static func integerValue(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let double as Double:
            return Int(double)
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func clampedMilliseconds(_ value: Int, allowedRange: ClosedRange<Int>) -> Int {
        clampedValue(value, allowedRange: allowedRange)
    }

    private static func clampedValue(_ value: Int, allowedRange: ClosedRange<Int>) -> Int {
        min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }
}

extension ExperimentConfigProvider {
    static let live = ExperimentConfigProvider { featureFlagKey in
        // getFeatureFlagResult records the experiment exposure and returns payload
        // in the same SDK call, keeping A/B attribution tied to config reads.
        guard let result = PostHogSDK.shared.getFeatureFlagResult(featureFlagKey) else {
            return nil
        }
        return ExperimentFlagEvaluation(
            variant: result.variant,
            payload: result.payload
        )
    }
}
