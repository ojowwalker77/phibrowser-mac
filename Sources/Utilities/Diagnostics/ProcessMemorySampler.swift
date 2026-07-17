// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation

final class ProcessMemorySampler: MemoryUsageSampling {
    private let rootPidProvider: () -> pid_t
    private let physicalMemoryProvider: () -> UInt64
    private let topProcessLimit: Int

    init(
        rootPidProvider: @escaping () -> pid_t = getpid,
        physicalMemoryProvider: @escaping () -> UInt64 = { ProcessInfo.processInfo.physicalMemory },
        topProcessLimit: Int = 15
    ) {
        self.rootPidProvider = rootPidProvider
        self.physicalMemoryProvider = physicalMemoryProvider
        self.topProcessLimit = topProcessLimit
    }

    func sample() -> MemoryUsageSnapshot? {
        let rootPid = rootPidProvider()
        let processRecords = allProcessIdentifiers()
            .compactMap { processInfo(for: $0, rootPid: rootPid) }

        guard processRecords.contains(where: { $0.pid == rootPid }) else {
            return nil
        }

        let childrenByParent = Dictionary(grouping: processRecords, by: \.ppid)
        let treeProcesses = processTree(rootPid: rootPid, childrenByParent: childrenByParent, records: processRecords)
        guard !treeProcesses.isEmpty else {
            return nil
        }

        let physicalMemoryBytes = physicalMemoryProvider()
        return MemoryUsageSnapshot(
            capturedAt: Date(),
            rootPid: rootPid,
            physicalMemoryBytes: physicalMemoryBytes,
            thresholdBytes: MemoryUsageThresholdPolicy.defaultThresholdBytes(
                physicalMemoryBytes: physicalMemoryBytes
            ),
            processes: treeProcesses,
            topProcessLimit: topProcessLimit
        )
    }

    private func allProcessIdentifiers() -> [pid_t] {
        let processCount = proc_listallpids(nil, 0)
        guard processCount > 0 else {
            return []
        }

        var pids = [pid_t](repeating: 0, count: Int(processCount) + 128)
        let pidBufferSize = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let returnedCount = pids.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return Int32(0)
            }

            return proc_listallpids(UnsafeMutableRawPointer(baseAddress), pidBufferSize)
        }

        guard returnedCount > 0 else {
            return []
        }

        return pids
            .prefix(Int(returnedCount))
            .filter { $0 > 0 }
    }

    private func processInfo(for pid: pid_t, rootPid: pid_t) -> ProcessMemoryInfo? {
        guard let bsdInfo = bsdInfo(for: pid),
              let taskInfo = taskInfo(for: pid) else {
            return nil
        }

        let name = processName(for: pid, bsdInfo: bsdInfo)
        let path = processPath(for: pid)
        let arguments = processArguments(for: pid)

        return ProcessMemoryInfo(
            pid: pid,
            ppid: pid_t(bsdInfo.pbi_ppid),
            name: name,
            path: path,
            residentBytes: UInt64(taskInfo.pti_resident_size),
            physicalFootprintBytes: physicalFootprint(for: pid),
            processType: processType(
                for: pid,
                rootPid: rootPid,
                name: name,
                path: path,
                arguments: arguments
            )
        )
    }

    private func physicalFootprint(for pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    private func processType(
        for pid: pid_t,
        rootPid: pid_t,
        name: String,
        path: String?,
        arguments: String?
    ) -> BrowserProcessType {
        if pid == rootPid { return .browser }

        let identity = "\(name) \(path ?? "") \(arguments ?? "")".lowercased()
        if identity.contains("--type=renderer") || identity.contains(" renderer") {
            return .renderer
        }
        if identity.contains("--type=gpu-process") || identity.contains("gpu process") {
            return .gpu
        }
        if identity.contains("networkservice") || identity.contains("network service") {
            return .network
        }
        if identity.contains("audioservice") || identity.contains("audio service") {
            return .audio
        }
        if identity.contains("video capture") || identity.contains("video_capture") {
            return .videoCapture
        }
        if identity.contains("storageservice") || identity.contains("storage service") {
            return .storage
        }
        if identity.contains("--type=utility") || identity.contains("phi helper") {
            return .utility
        }
        return .other
    }

    /// Reads the process argument block so Chromium helpers can be classified
    /// by their `--type` and `--utility-sub-type` switches. Name and executable
    /// path alone label most children only as "Phi Helper".
    private func processArguments(for pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, UInt32(mib.count), bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }

        // KERN_PROCARGS2 is argc followed by NUL-separated executable, argv,
        // and environment strings. Classification only needs searchable text.
        let payload = buffer.dropFirst(MemoryLayout<Int32>.size).prefix(size)
        return String(decoding: payload.map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
    }

    private func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                UnsafeMutableRawPointer(pointer),
                Int32(size)
            )
        }

        guard result == Int32(size) else {
            return nil
        }

        return info
    }

    private func taskInfo(for pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTASKINFO,
                0,
                UnsafeMutableRawPointer(pointer),
                Int32(size)
            )
        }

        guard result == Int32(size) else {
            return nil
        }

        return info
    }

    private func processName(for pid: pid_t, bsdInfo: proc_bsdinfo) -> String {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let nameLength = nameBuffer.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return Int32(0)
            }

            return proc_name(pid, UnsafeMutableRawPointer(baseAddress), UInt32(buffer.count))
        }

        if nameLength > 0 {
            return String(cString: nameBuffer)
        }

        let fallbackName = bsdProcessName(from: bsdInfo)
        return fallbackName.isEmpty ? "pid-\(pid)" : fallbackName
    }

    private func bsdProcessName(from info: proc_bsdinfo) -> String {
        withUnsafePointer(to: info.pbi_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { namePointer in
                let nameBuffer = UnsafeBufferPointer(start: namePointer, count: Int(MAXCOMLEN))
                let nameBytes = nameBuffer
                    .prefix { $0 != 0 }
                    .map { UInt8(bitPattern: $0) }
                return String(decoding: nameBytes, as: UTF8.self)
            }
        }
    }

    private func processPath(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return Int32(0)
            }

            return proc_pidpath(pid, UnsafeMutableRawPointer(baseAddress), UInt32(buffer.count))
        }

        guard pathLength > 0 else {
            return nil
        }

        return String(cString: pathBuffer)
    }

    private func processTree(
        rootPid: pid_t,
        childrenByParent: [pid_t: [ProcessMemoryInfo]],
        records: [ProcessMemoryInfo]
    ) -> [ProcessMemoryInfo] {
        let recordsByPid = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
        guard let rootProcess = recordsByPid[rootPid] else {
            return []
        }

        var treeProcesses: [ProcessMemoryInfo] = []
        var visited = Set<pid_t>()
        var stack = [rootProcess]

        while let process = stack.popLast() {
            guard visited.insert(process.pid).inserted else {
                continue
            }

            treeProcesses.append(process)
            if let children = childrenByParent[process.pid] {
                stack.append(contentsOf: children)
            }
        }

        return treeProcesses
    }
}
