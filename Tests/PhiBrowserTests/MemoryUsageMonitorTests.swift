// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class MemoryUsageMonitorTests: XCTestCase {
    func testMonitorReportsOnceWhenSnapshotExceedsThreshold() {
        let sampler = StubMemoryUsageSampler(snapshots: [
            makeSnapshot(totalResidentBytes: 9 * 1024 * 1024 * 1024)
        ])
        let reporter = RecordingMemoryUsageReporter()
        let monitor = MemoryUsageMonitor(
            sampler: sampler,
            reporter: reporter,
            now: { Date(timeIntervalSince1970: 1_713_600_000) }
        )

        monitor.sampleOnceForTesting()

        XCTAssertEqual(reporter.snapshots.count, 1)
        XCTAssertEqual(reporter.snapshots.first?.totalResidentBytes, 9 * 1024 * 1024 * 1024)
    }

    func testMonitorSuppressesReportsDuringCooldown() {
        var currentDate = Date(timeIntervalSince1970: 1_713_600_000)
        let sampler = StubMemoryUsageSampler(snapshots: [
            makeSnapshot(totalResidentBytes: 9 * 1024 * 1024 * 1024),
            makeSnapshot(totalResidentBytes: 10 * 1024 * 1024 * 1024)
        ])
        let reporter = RecordingMemoryUsageReporter()
        let monitor = MemoryUsageMonitor(
            sampler: sampler,
            reporter: reporter,
            cooldown: 30 * 60,
            now: { currentDate }
        )

        monitor.sampleOnceForTesting()
        currentDate = currentDate.addingTimeInterval(10 * 60)
        monitor.sampleOnceForTesting()

        XCTAssertEqual(reporter.snapshots.count, 1)
        XCTAssertEqual(reporter.snapshots.first?.totalResidentBytes, 9 * 1024 * 1024 * 1024)
    }

    func testMonitorReportsAgainAfterCooldown() {
        var currentDate = Date(timeIntervalSince1970: 1_713_600_000)
        let sampler = StubMemoryUsageSampler(snapshots: [
            makeSnapshot(totalResidentBytes: 9 * 1024 * 1024 * 1024),
            makeSnapshot(totalResidentBytes: 10 * 1024 * 1024 * 1024)
        ])
        let reporter = RecordingMemoryUsageReporter()
        let monitor = MemoryUsageMonitor(
            sampler: sampler,
            reporter: reporter,
            cooldown: 30 * 60,
            now: { currentDate }
        )

        monitor.sampleOnceForTesting()
        currentDate = currentDate.addingTimeInterval(31 * 60)
        monitor.sampleOnceForTesting()

        XCTAssertEqual(reporter.snapshots.count, 2)
        XCTAssertEqual(reporter.snapshots.last?.totalResidentBytes, 10 * 1024 * 1024 * 1024)
    }

    func testMonitorResetsAfterMemoryDropsBelowThreshold() {
        var currentDate = Date(timeIntervalSince1970: 1_713_600_000)
        let sampler = StubMemoryUsageSampler(snapshots: [
            makeSnapshot(totalResidentBytes: 9 * 1024 * 1024 * 1024),
            makeSnapshot(totalResidentBytes: 7 * 1024 * 1024 * 1024),
            makeSnapshot(totalResidentBytes: 10 * 1024 * 1024 * 1024)
        ])
        let reporter = RecordingMemoryUsageReporter()
        let monitor = MemoryUsageMonitor(
            sampler: sampler,
            reporter: reporter,
            cooldown: 30 * 60,
            now: { currentDate }
        )

        monitor.sampleOnceForTesting()
        currentDate = currentDate.addingTimeInterval(5 * 60)
        monitor.sampleOnceForTesting()
        currentDate = currentDate.addingTimeInterval(5 * 60)
        monitor.sampleOnceForTesting()

        XCTAssertEqual(reporter.snapshots.count, 2)
        XCTAssertEqual(reporter.snapshots.last?.totalResidentBytes, 10 * 1024 * 1024 * 1024)
    }

    func testThresholdUsesClampedPhysicalMemoryPolicy() {
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        let cases: [(physicalMemoryGB: UInt64, expectedThresholdGB: UInt64)] = [
            (8, 4),
            (16, 8),
            (32, 12)
        ]

        for testCase in cases {
            let threshold = MemoryUsageThresholdPolicy.defaultThresholdBytes(
                physicalMemoryBytes: testCase.physicalMemoryGB * gigabyte
            )

            XCTAssertEqual(
                threshold,
                testCase.expectedThresholdGB * gigabyte,
                "\(testCase.physicalMemoryGB)GB physical memory should use a \(testCase.expectedThresholdGB)GB threshold"
            )
        }
    }

    func testSnapshotKeepsTopProcessesSortedAndCapped() {
        let processes = (0..<12).map { index in
            ProcessMemoryInfo(
                pid: pid_t(index),
                ppid: 1,
                name: "process-\(index)",
                path: nil,
                residentBytes: UInt64(index + 1) * 1024
            )
        }

        let snapshot = MemoryUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_713_600_000),
            rootPid: 100,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            thresholdBytes: 8 * 1024 * 1024 * 1024,
            processes: processes,
            topProcessLimit: 10
        )

        XCTAssertEqual(snapshot.topProcesses.count, 10)
        XCTAssertEqual(snapshot.topProcesses.first?.name, "process-11")
        XCTAssertEqual(snapshot.topProcesses.last?.name, "process-2")
        XCTAssertEqual(snapshot.processCount, 12)
        XCTAssertEqual(snapshot.totalResidentBytes, UInt64((1...12).reduce(0, +)) * 1024)
    }

    func testProcessMemorySamplerIncludesCurrentProcess() {
        let sampler = ProcessMemorySampler()

        let snapshot = sampler.sample()

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.rootPid, getpid())
        XCTAssertTrue(snapshot?.processes.contains { $0.pid == getpid() } == true)
        XCTAssertGreaterThan(snapshot?.totalResidentBytes ?? 0, 0)
        XCTAssertGreaterThan(snapshot?.rootPhysicalFootprintBytes ?? 0, 0)
    }

    func testSnapshotUsesFootprintAndReportsTypedDistributions() {
        let gibibyte: UInt64 = 1024 * 1024 * 1024
        let snapshot = MemoryUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_713_600_000),
            rootPid: 10,
            physicalMemoryBytes: 16 * gibibyte,
            thresholdBytes: 4 * gibibyte,
            processes: [
                ProcessMemoryInfo(
                    pid: 10,
                    ppid: 1,
                    name: "Phi",
                    path: nil,
                    residentBytes: 2 * gibibyte,
                    physicalFootprintBytes: 3 * gibibyte,
                    processType: .browser
                ),
                ProcessMemoryInfo(
                    pid: 11,
                    ppid: 10,
                    name: "Phi Helper (Renderer)",
                    path: nil,
                    residentBytes: gibibyte,
                    physicalFootprintBytes: 2 * gibibyte,
                    processType: .renderer
                )
            ]
        )

        XCTAssertEqual(snapshot.totalResidentBytes, 3 * gibibyte)
        XCTAssertEqual(snapshot.totalPhysicalFootprintBytesEstimate, 5 * gibibyte)
        XCTAssertEqual(snapshot.monitoringBytes, 5 * gibibyte)
        XCTAssertEqual(snapshot.rootPhysicalFootprintBytes, 3 * gibibyte)
        XCTAssertEqual(snapshot.physicalFootprintByProcessType[.renderer]?.count, 1)
        XCTAssertEqual(snapshot.physicalFootprintByProcessType[.renderer]?.p95Bytes, 2 * gibibyte)
        XCTAssertTrue(snapshot.exceedsThreshold)
    }

    func testSentryContextUsesStablePayloadShape() {
        let capturedAt = Date(timeIntervalSince1970: 1_713_600_000)
        let process = ProcessMemoryInfo(
            pid: 123,
            ppid: 45,
            name: "Phi Browser",
            path: "/Applications/Phi.app",
            residentBytes: 2 * 1024 * 1024 * 1024
        )
        let snapshot = MemoryUsageSnapshot(
            capturedAt: capturedAt,
            rootPid: 100,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            thresholdBytes: 8 * 1024 * 1024 * 1024,
            processes: [process]
        )

        let processContext = process.sentryContext
        XCTAssertEqual(processContext["pid"] as? Int, 123)
        XCTAssertEqual(processContext["ppid"] as? Int, 45)
        XCTAssertEqual(processContext["residentGB"] as? Double, 2)
        XCTAssertEqual(processContext["path"] as? String, "/Applications/Phi.app")

        let snapshotContext = snapshot.sentryContext
        XCTAssertEqual(snapshotContext["capturedAt"] as? String, ISO8601DateFormatter().string(from: capturedAt))
        XCTAssertEqual(snapshotContext["rootPid"] as? Int, 100)
        XCTAssertEqual(snapshotContext["physicalMemoryGB"] as? Double, 16)
        XCTAssertEqual(snapshotContext["thresholdGB"] as? Double, 8)
        XCTAssertEqual(snapshotContext["totalResidentGB"] as? Double, 2)
    }

    private func makeSnapshot(totalResidentBytes: UInt64) -> MemoryUsageSnapshot {
        MemoryUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_713_600_000),
            rootPid: 100,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            thresholdBytes: 8 * 1024 * 1024 * 1024,
            processes: [
                ProcessMemoryInfo(
                    pid: 100,
                    ppid: 1,
                    name: "Phi",
                    path: nil,
                    residentBytes: totalResidentBytes
                )
            ]
        )
    }
}

private final class StubMemoryUsageSampler: MemoryUsageSampling {
    private var snapshots: [MemoryUsageSnapshot?]

    init(snapshots: [MemoryUsageSnapshot?]) {
        self.snapshots = snapshots
    }

    func sample() -> MemoryUsageSnapshot? {
        guard !snapshots.isEmpty else {
            return nil
        }

        return snapshots.removeFirst()
    }
}

private final class RecordingMemoryUsageReporter: MemoryUsageReporting {
    private(set) var snapshots: [MemoryUsageSnapshot] = []

    func reportMemoryThresholdExceeded(snapshot: MemoryUsageSnapshot) {
        snapshots.append(snapshot)
    }
}
