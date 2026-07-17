// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct MemoryUsageThresholdPolicy {
    static let minimumThresholdBytes: UInt64 = 4 * 1024 * 1024 * 1024
    static let maximumThresholdBytes: UInt64 = 12 * 1024 * 1024 * 1024

    static func defaultThresholdBytes(physicalMemoryBytes: UInt64) -> UInt64 {
        min(max(minimumThresholdBytes, physicalMemoryBytes / 2), maximumThresholdBytes)
    }
}

enum BrowserProcessType: String, CaseIterable, Equatable, Hashable {
    case browser
    case renderer
    case gpu
    case network
    case audio
    case videoCapture
    case storage
    case utility
    case other
}

struct ProcessMemoryInfo: Equatable {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let path: String?
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64?
    let processType: BrowserProcessType

    init(
        pid: pid_t,
        ppid: pid_t,
        name: String,
        path: String?,
        residentBytes: UInt64,
        physicalFootprintBytes: UInt64? = nil,
        processType: BrowserProcessType = .other
    ) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.processType = processType
    }

    var preferredSortBytes: UInt64 {
        physicalFootprintBytes ?? residentBytes
    }

    var sentryContext: [String: Any] {
        var context: [String: Any] = [
            "pid": Int(pid),
            "ppid": Int(ppid),
            "name": name,
            "processType": processType.rawValue,
            "residentBytes": residentBytes,
            "residentGB": Double(residentBytes) / Double(1024 * 1024 * 1024)
        ]

        if let physicalFootprintBytes {
            context["physicalFootprintBytes"] = physicalFootprintBytes
            context["physicalFootprintGB"] = Double(physicalFootprintBytes) / Double(1024 * 1024 * 1024)
        }

        if let path {
            context["path"] = path
        }

        return context
    }
}

struct ProcessMemoryDistribution: Equatable {
    let count: Int
    let totalBytes: UInt64
    let medianBytes: UInt64
    let p95Bytes: UInt64
    let maximumBytes: UInt64

    init(values: [UInt64]) {
        let sorted = values.sorted()
        count = sorted.count
        totalBytes = sorted.reduce(0, +)
        medianBytes = Self.percentile(0.5, sorted: sorted)
        p95Bytes = Self.percentile(0.95, sorted: sorted)
        maximumBytes = sorted.last ?? 0
    }

    private static func percentile(_ percentile: Double, sorted: [UInt64]) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(ceil(percentile * Double(sorted.count))) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    var sentryContext: [String: Any] {
        [
            "count": count,
            "totalBytes": totalBytes,
            "medianBytes": medianBytes,
            "p95Bytes": p95Bytes,
            "maximumBytes": maximumBytes
        ]
    }
}

struct MemoryUsageSnapshot: Equatable {
    let capturedAt: Date
    let rootPid: pid_t
    let physicalMemoryBytes: UInt64
    let thresholdBytes: UInt64
    let processes: [ProcessMemoryInfo]
    let topProcesses: [ProcessMemoryInfo]

    init(
        capturedAt: Date,
        rootPid: pid_t,
        physicalMemoryBytes: UInt64,
        thresholdBytes: UInt64,
        processes: [ProcessMemoryInfo],
        topProcessLimit: Int = 10
    ) {
        self.capturedAt = capturedAt
        self.rootPid = rootPid
        self.physicalMemoryBytes = physicalMemoryBytes
        self.thresholdBytes = thresholdBytes
        self.processes = processes
        self.topProcesses = Array(
            processes
                .sorted { $0.preferredSortBytes > $1.preferredSortBytes }
                .prefix(max(0, topProcessLimit))
        )
    }

    var totalResidentBytes: UInt64 {
        processes.reduce(0) { $0 + $1.residentBytes }
    }

    /// Directional estimate only. Process footprints can contain shared
    /// graphics allocations, so callers must not present this as exact app RAM.
    var totalPhysicalFootprintBytesEstimate: UInt64 {
        processes.compactMap(\.physicalFootprintBytes).reduce(0, +)
    }

    var rootPhysicalFootprintBytes: UInt64? {
        processes.first(where: { $0.pid == rootPid })?.physicalFootprintBytes
    }

    var physicalFootprintByProcessType: [BrowserProcessType: ProcessMemoryDistribution] {
        let grouped = Dictionary(
            grouping: processes.compactMap { process -> (BrowserProcessType, UInt64)? in
                guard let footprint = process.physicalFootprintBytes else { return nil }
                return (process.processType, footprint)
            },
            by: { $0.0 }
        )
        return grouped.mapValues { entries in
            ProcessMemoryDistribution(values: entries.map { $0.1 })
        }
    }

    var monitoringBytes: UInt64 {
        let footprint = totalPhysicalFootprintBytesEstimate
        return footprint > 0 ? footprint : totalResidentBytes
    }

    var processCount: Int {
        processes.count
    }

    var exceedsThreshold: Bool {
        monitoringBytes > thresholdBytes
    }

    var sentryContext: [String: Any] {
        var context: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: capturedAt),
            "rootPid": Int(rootPid),
            "physicalMemoryBytes": physicalMemoryBytes,
            "physicalMemoryGB": Double(physicalMemoryBytes) / Double(1024 * 1024 * 1024),
            "thresholdBytes": thresholdBytes,
            "thresholdGB": Double(thresholdBytes) / Double(1024 * 1024 * 1024),
            "totalResidentBytes": totalResidentBytes,
            "totalResidentGB": Double(totalResidentBytes) / Double(1024 * 1024 * 1024),
            "totalPhysicalFootprintBytesEstimate": totalPhysicalFootprintBytesEstimate,
            "totalPhysicalFootprintGBEstimate": Double(totalPhysicalFootprintBytesEstimate) / Double(1024 * 1024 * 1024),
            "monitoringBytes": monitoringBytes,
            "processCount": processCount,
            "exceedsThreshold": exceedsThreshold,
            "topProcesses": topProcesses.map(\.sentryContext)
        ]
        if let rootPhysicalFootprintBytes {
            context["rootPhysicalFootprintBytes"] = rootPhysicalFootprintBytes
        }
        context["physicalFootprintByProcessType"] = Dictionary(
            uniqueKeysWithValues: physicalFootprintByProcessType.map { type, distribution in
                (type.rawValue, distribution.sentryContext)
            }
        )
        return context
    }
}
