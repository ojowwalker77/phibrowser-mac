// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

protocol MemoryUsageSampling: AnyObject {
    func sample() -> MemoryUsageSnapshot?
}

protocol MemoryUsageReporting: AnyObject {
    func reportMemoryThresholdExceeded(snapshot: MemoryUsageSnapshot)
}

final class MemoryUsageMonitor {
    static let shared = MemoryUsageMonitor(
        sampler: ProcessMemorySampler(),
        reporter: SentryMemoryUsageReporter()
    )

    private let sampler: MemoryUsageSampling
    private let reporter: MemoryUsageReporting
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let cooldown: TimeInterval
    private let now: () -> Date

    private var timer: DispatchSourceTimer?
    private var lastReportDate: Date?
    private var didDropBelowThresholdAfterReport = false

    init(
        sampler: MemoryUsageSampling,
        reporter: MemoryUsageReporting,
        queue: DispatchQueue = DispatchQueue(label: "com.phi.memory-usage-monitor", qos: .utility),
        interval: TimeInterval = 60 * 10,
        cooldown: TimeInterval = 60 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.sampler = sampler
        self.reporter = reporter
        self.queue = queue
        self.interval = interval
        self.cooldown = cooldown
        self.now = now
    }

    func start() {
        queue.sync {
            guard timer == nil else {
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now(),
                repeating: .milliseconds(max(1, Int(interval * 1_000))),
                leeway: .seconds(5)
            )
            timer.setEventHandler { [weak self] in
                self?.sampleAndReportIfNeeded()
            }
            self.timer = timer
            timer.resume()
            AppLogDebug("[MemoryMonitor] started")
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            AppLogDebug("[MemoryMonitor] stopped")
        }
    }

    func sampleOnceForTesting() {
        queue.sync {
            sampleAndReportIfNeeded()
        }
    }

    private func sampleAndReportIfNeeded() {
        guard let snapshot = sampler.sample() else {
            AppLogDebug("[MemoryMonitor] Memory sample returned nil")
            return
        }
        
        AppLogDebug("current memeory usage: \(Double(snapshot.totalResidentBytes) / Double(1024 * 1024 * 1024))GB")
        
        guard snapshot.exceedsThreshold else {
            didDropBelowThresholdAfterReport = lastReportDate != nil
            return
        }

        let currentDate = now()
        guard shouldReport(at: currentDate) else {
            return
        }

        AppLogWarn(
            "[MemoryMonitor] Memory threshold exceeded: totalResidentBytes=\(snapshot.totalResidentBytes), thresholdBytes=\(snapshot.thresholdBytes)"
        )
        reporter.reportMemoryThresholdExceeded(snapshot: snapshot)
        lastReportDate = currentDate
        didDropBelowThresholdAfterReport = false
    }

    private func shouldReport(at currentDate: Date) -> Bool {
        guard let lastReportDate else {
            return true
        }

        if didDropBelowThresholdAfterReport {
            return true
        }

        return currentDate.timeIntervalSince(lastReportDate) >= cooldown
    }
}

private final class SentryMemoryUsageReporter: MemoryUsageReporting {
    func reportMemoryThresholdExceeded(snapshot: MemoryUsageSnapshot) {
        SentryService.captureMemoryThresholdExceeded(snapshot: snapshot)
    }
}
