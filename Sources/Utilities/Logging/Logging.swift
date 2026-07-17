// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CocoaLumberjack
import CocoaLumberjackSwift
import Darwin
import Foundation
import os

struct PhiLogging {
    static func applicationLog(maxLength length: Int) -> String? {
        guard let fileLogger = DDLog.sharedInstance.allLoggers.first(where: { $0 is DDFileLogger }) as? DDFileLogger else {
            return nil
        }
        let manager = fileLogger.logFileManager
        let logFiles = manager.sortedLogFilePaths
        var logEntries = ""
        var charsLeftToRead = length
        
        var index = 0
        while charsLeftToRead > 0 && index < logFiles.count {
            autoreleasepool {
                let logFilePath = logFiles[index]
                do {
                    var logFileString = try String(contentsOfFile: logFilePath, encoding: .utf8)
                    let nsString = logFileString as NSString
                    let fileLength = nsString.length
                    
                    if fileLength > charsLeftToRead {
                        var start = 0
                        var end = 0
                        let cutIndex = fileLength - charsLeftToRead
                        var cut = cutIndex
                        nsString.getLineStart(&start, end: &end, contentsEnd: nil, for: NSRange(location: cutIndex, length: 0))
                        if start < cutIndex {
                            // Move forward to the next full line to avoid truncation.
                            cut = end
                        }
                        logFileString = nsString.substring(from: cut)
                        charsLeftToRead = 0
                    } else {
                        charsLeftToRead -= fileLength
                    }
                    
                    // Prepend older files so the final output stays chronological.
                    logEntries.insert(contentsOf: logFileString, at: logEntries.startIndex)
                } catch {
                    AppLogError("Unable to read log file: \(logFilePath)")
                }
            }
            index += 1
        }
        
        return logEntries
    }
}
// Default log level for the app.
public let DDDefaultLogLevel: DDLogLevel = .error

private enum PhiLoggingInstallation {
    static var didInstall = false
}

/// Installs file + OS loggers once. Call `[PhiLoggingRuntime installSharedLogging]` from `main.m` before any Objective-C
/// `AppLog*` / `DDLog*`; `applicationWillFinishLaunching` also calls this as a fallback.
/// Repeat calls are no-ops so `DDFileLogger` is never torn down (which would roll the current file).
public func setupLogging() {
    if PhiLoggingInstallation.didInstall { return }

    let consoleLogger = DDOSLogger.sharedInstance
    consoleLogger.logFormatter = PhiLogFormatter()
    
    let fileManager = DDLogFileManagerDefault(logsDirectory: getLogsDirectory())
    let fileLogger = DDFileLogger(logFileManager: fileManager)
    fileLogger.rollingFrequency = 24 * 60 * 60 // Rotate daily.
    fileLogger.logFileManager.maximumNumberOfLogFiles = 7
    fileLogger.maximumFileSize = 5 * 1024 * 1024
    fileLogger.logFormatter = PhiLogFormatter()
#if DEBUG
    let logLevel: DDLogLevel = .all
#else
    let verboseLoggingEnabled = ProcessInfo.processInfo.arguments.contains("-phiVerboseLogging")
        || ProcessInfo.processInfo.environment["PHI_VERBOSE_LOGGING"] == "1"
    let logLevel: DDLogLevel = verboseLoggingEnabled ? .all : .info
#endif
    DDLog.add(fileLogger, with: logLevel)
    DDLog.add(consoleLogger, with: logLevel)
    PhiLoggingInstallation.didInstall = true
    PerformanceJourneys.startAppLaunchIfNeeded()
#if PERFORMANCE_PROFILE
    PerformanceBuildManifest.log()
#endif
}

/// Entry point for Objective-C (`main.m`, Chromium launcher) so logging is installed before any `AppLog*`
/// or `DDLog*` calls. Swift global functions are not visible to ObjC; use this instead of calling
/// `setupLogging()` from `.m` files.
@objc(PhiLoggingRuntime)
public final class PhiLoggingRuntime: NSObject {
    @objc public static func installSharedLogging() {
        setupLogging()
    }
}

/// Returns the app log directory.
private func getLogsDirectory() -> String {
    let phiDataDir = FileSystemUtils.phiBrowserDataDirectory()
    return (phiDataDir as NSString)
        .appendingPathComponent("PhiLogs")
}

// MARK: - Public Logging Functions
public func AppLogInfo(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogInfo("\(logText())", file: file, function: function, line: line)
}

public func AppLogError(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogError("\(logText())", file: file, function: function, line: line)
}

public func AppLogWarn(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogWarn("\(logText())", file: file, function: function, line: line)
}

public func AppLogDebug(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogDebug("\(logText())", file: file, function: function, line: line)
}

public func AppLogVerbose(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogVerbose("\(logText())", file: file, function: function, line: line)
}

// MARK: - Convenience Logging Functions

/// Logs a user action.
public func AppLogUserAction(_ action: String, details: String? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    let message = details != nil ? "\(action) - \(details!)" : action
    DDLogInfo("👤 \(message)", file: file, function: function, line: line)
}

/// Logs a network request.
public func AppLogNetwork(_ method: String, url: String, statusCode: Int? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    let status = statusCode != nil ? " [\(statusCode!)]" : ""
    DDLogInfo("🌐 \(method) \(url)\(status)", file: file, function: function, line: line)
}

/// Logs a performance measurement.
public func AppLogPerformance(_ operation: String, duration: TimeInterval, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogInfo("⏱️ \(operation) took \(String(format: "%.3f", duration))s", file: file, function: function, line: line)
}

/// A typed interval handle for Instruments points-of-interest. Keep the handle
/// with the owner of the user journey and end it when that journey settles.
struct PerformanceInterval {
    fileprivate let name: StaticString
    fileprivate let state: OSSignpostIntervalState

    func end(_ metadata: String = "") {
        PerformanceSignposts.end(self, metadata: metadata)
    }
}

/// Stable performance signposts shared by the existing diagnostics/logging
/// layer. Logs remain useful narrative evidence; these intervals provide the
/// duration and causal structure Instruments needs.
enum PerformanceSignposts {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.phibrowser.Mac",
        category: "Performance"
    )

    static func begin(_ name: StaticString, metadata: String = "") -> PerformanceInterval {
        let state = signposter.beginInterval(name, "\(metadata, privacy: .public)")
        return PerformanceInterval(name: name, state: state)
    }

    static func end(_ interval: PerformanceInterval, metadata: String = "") {
        signposter.endInterval(
            interval.name,
            interval.state,
            "\(metadata, privacy: .public)"
        )
    }

    static func event(_ name: StaticString, metadata: String = "") {
        signposter.emitEvent(name, "\(metadata, privacy: .public)")
    }

    static func measure<T>(
        _ name: StaticString,
        metadata: String = "",
        operation: () throws -> T
    ) rethrows -> T {
        let interval = begin(name, metadata: metadata)
        defer { interval.end() }
        return try operation()
    }
}

/// Cross-owner journeys whose begin/end points naturally live in different
/// layers. This remains diagnostics-only and does not own application state.
enum PerformanceJourneys {
    private static var appLaunchInterval: PerformanceInterval?
    private static var firstUsableWindowObserver: NSObjectProtocol?

    static func startAppLaunchIfNeeded() {
        guard appLaunchInterval == nil else { return }
        appLaunchInterval = PerformanceSignposts.begin("app.firstUsableWindow")
    }

    static func observeFirstUsableWindow(_ window: NSWindow, windowId: Int) {
        guard appLaunchInterval != nil, firstUsableWindowObserver == nil else { return }
        if window.isKeyWindow {
            finishAppLaunch(windowId: windowId)
            return
        }

        firstUsableWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let keyWindow = notification.object as? NSWindow,
                  let controller = keyWindow.windowController as? MainBrowserWindowController else {
                return
            }
            finishAppLaunch(windowId: controller.windowId)
        }
    }

    private static func finishAppLaunch(windowId: Int) {
        guard let interval = appLaunchInterval else { return }
        appLaunchInterval = nil
        if let observer = firstUsableWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            firstUsableWindowObserver = nil
        }
        interval.end("windowId=\(windowId)")
    }
}

#if PERFORMANCE_PROFILE
private enum PerformanceBuildManifest {
    static func log() {
        let info = Bundle.main.infoDictionary ?? [:]
        let processInfo = ProcessInfo.processInfo
        let verboseLoggingEnabled = processInfo.arguments.contains("-phiVerboseLogging")
            || processInfo.environment["PHI_VERBOSE_LOGGING"] == "1"
        AppLogInfo(
            "[PerformanceBuild] revision=\(info["PhiBuildRevision"] as? String ?? "unknown") " +
            "configuration=\(info["PhiBuildConfiguration"] as? String ?? "unknown") " +
            "architecture=\(info["PhiBuildArchitecture"] as? String ?? systemValue("hw.machine")) " +
            "swiftOptimization=\(info["PhiSwiftOptimizationLevel"] as? String ?? "unknown") " +
            "testability=\(info["PhiEnableTestability"] as? String ?? "unknown") " +
            "verboseLogging=\(verboseLoggingEnabled) " +
            "framework=\(info["PhiFrameworkVersion"] as? String ?? "unknown") " +
            "os=\(processInfo.operatingSystemVersionString) " +
            "model=\(systemValue("hw.model")) physicalMemoryBytes=\(processInfo.physicalMemory)"
        )
    }

    private static func systemValue(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: value)
    }
}
#endif

/// Logs a memory warning.
public func AppLogMemoryWarning(_ message: String = "Memory warning received", file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogWarn("🧠 \(message)", file: file, function: function, line: line)
}
