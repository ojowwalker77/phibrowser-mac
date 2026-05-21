// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ExperimentConfigProviderTests: XCTestCase {
    func testTimeoutConfigUsesPayloadValueAndRecordsVariantAttribution() {
        var requestedKeys: [String] = []
        let provider = ExperimentConfigProvider { key in
            requestedKeys.append(key)
            return ExperimentFlagEvaluation(
                variant: "test",
                payload: ["timeout_ms": 8_000]
            )
        }
        let config = ExperimentTimeoutConfig(
            featureFlagKey: "request-timeout-experiment",
            defaultMilliseconds: 5_000,
            allowedRange: 1_000...30_000
        )

        let resolved = provider.resolveTimeout(config)

        XCTAssertEqual(resolved.milliseconds, 8_000)
        XCTAssertEqual(resolved.variant, "test")
        XCTAssertEqual(resolved.featureProperties["$feature/request-timeout-experiment"] as? String, "test")
        XCTAssertEqual(requestedKeys, ["request-timeout-experiment"])
    }

    func testTimeoutConfigFallsBackToDefaultWhenPayloadIsMissing() {
        let provider = ExperimentConfigProvider { _ in
            ExperimentFlagEvaluation(variant: "control", payload: nil)
        }
        let config = ExperimentTimeoutConfig(
            featureFlagKey: "request-timeout-experiment",
            defaultMilliseconds: 5_000,
            allowedRange: 1_000...30_000
        )

        let resolved = provider.resolveTimeout(config)

        XCTAssertEqual(resolved.milliseconds, 5_000)
        XCTAssertEqual(resolved.featureProperties["$feature/request-timeout-experiment"] as? String, "control")
    }

    func testTimeoutConfigClampsPayloadValueToAllowedRange() {
        let lowProvider = ExperimentConfigProvider { _ in
            ExperimentFlagEvaluation(variant: "test", payload: ["timeout_ms": 100])
        }
        let highProvider = ExperimentConfigProvider { _ in
            ExperimentFlagEvaluation(variant: "test", payload: ["timeout_ms": 60_000])
        }
        let config = ExperimentTimeoutConfig(
            featureFlagKey: "request-timeout-experiment",
            defaultMilliseconds: 5_000,
            allowedRange: 1_000...30_000
        )

        XCTAssertEqual(lowProvider.resolveTimeout(config).milliseconds, 1_000)
        XCTAssertEqual(highProvider.resolveTimeout(config).milliseconds, 30_000)
    }

    func testTimeoutConfigSupportsNumericStringPayloads() {
        let provider = ExperimentConfigProvider { _ in
            ExperimentFlagEvaluation(variant: "test", payload: ["timeout_ms": "7500"])
        }
        let config = ExperimentTimeoutConfig(
            featureFlagKey: "request-timeout-experiment",
            defaultMilliseconds: 5_000,
            allowedRange: 1_000...30_000
        )

        let resolved = provider.resolveTimeout(config)

        XCTAssertEqual(resolved.milliseconds, 7_500)
    }

    func testAuth0RefreshConfigUsesPayloadValuesAndRecordsVariantAttribution() {
        var requestedKeys: [String] = []
        let provider = ExperimentConfigProvider { key in
            requestedKeys.append(key)
            return ExperimentFlagEvaluation(
                variant: "short-window",
                payload: [
                    "refresh_check_interval_seconds": 1_800,
                    "refresh_urgent_window_seconds": 900
                ]
            )
        }

        let resolved = provider.resolveAuth0RefreshConfig(.auth0RefreshTimingExperiment)

        XCTAssertEqual(resolved.checkInterval, 1_800)
        XCTAssertEqual(resolved.urgentWindow, 900)
        XCTAssertEqual(resolved.variant, "short-window")
        XCTAssertEqual(resolved.featureProperties["$feature/auth0-refresh-timing"] as? String, "short-window")
        XCTAssertEqual(requestedKeys, ["auth0-refresh-timing"])
    }

    func testAuth0RefreshConfigFallsBackToDefaultsWhenPayloadIsMissing() {
        let provider = ExperimentConfigProvider { _ in
            ExperimentFlagEvaluation(variant: "control", payload: nil)
        }

        let resolved = provider.resolveAuth0RefreshConfig(.auth0RefreshTimingExperiment)

        XCTAssertEqual(resolved.checkInterval, 3_600)
        XCTAssertEqual(resolved.urgentWindow, 3_600)
        XCTAssertEqual(resolved.featureProperties["$feature/auth0-refresh-timing"] as? String, "control")
    }

    func testAuth0RefreshConfigClampsPayloadValuesToAllowedRanges() {
        let lowProvider = ExperimentConfigProvider { _ in
            ExperimentFlagEvaluation(
                variant: "test",
                payload: [
                    "refresh_check_interval_seconds": 30,
                    "refresh_urgent_window_seconds": 30
                ]
            )
        }
        let highProvider = ExperimentConfigProvider { _ in
            ExperimentFlagEvaluation(
                variant: "test",
                payload: [
                    "refresh_check_interval_seconds": 172_800,
                    "refresh_urgent_window_seconds": 1_000_000
                ]
            )
        }

        XCTAssertEqual(lowProvider.resolveAuth0RefreshConfig(.auth0RefreshTimingExperiment).checkInterval, 300)
        XCTAssertEqual(lowProvider.resolveAuth0RefreshConfig(.auth0RefreshTimingExperiment).urgentWindow, 300)
        XCTAssertEqual(highProvider.resolveAuth0RefreshConfig(.auth0RefreshTimingExperiment).checkInterval, 86_400)
        XCTAssertEqual(highProvider.resolveAuth0RefreshConfig(.auth0RefreshTimingExperiment).urgentWindow, 604_800)
    }
}
