// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftData
import CocoaLumberjackSwift
import Kingfisher
import Sparkle
import Settings

@objc class AppController: NSObject, NSApplicationDelegate {
    @IBOutlet var window: NSWindow!
    @objc static private(set)var shared: AppController!
    
    var settingsWindowController: SettingsWindowController?
    
    var container: ModelContainer?
    var updater: SPUUpdater?
    var sparkleUserDriver: PhiSparkleUserDriver?
    /// Sparkle update state
    var updateState: UpdateState = .idle {
        didSet {
            DispatchQueue.main.async {
                self.updateCheckForUpdateMenuItem()
            }
        }
    }
    
    var menuObservation: NSKeyValueObservation?

    /// Defer forwarding cold-launch URLs until Chromium session restore registers
    /// the first tabbed `Browser` (see `OpenUrlsInBrowserWithProfile`).
    private static let coldOpenURLForwardDelay: TimeInterval = 0.5
    private var coldOpenURLForwardWorkItem: DispatchWorkItem?
    private var pendingColdOpenForwardURLs: [URL] = []
    /// Cached in `applicationWillFinishLaunching`; weak — owned by `ChromiumLauncher`, not AppController.
    private weak var chromiumBridge: (any PhiChromiumBridgeProtocol)?

    override init() {
        super.init()
        Self.shared = self
        // Opt out of AppKit's window-state restoration. macOS otherwise
        // re-enters native fullscreen on a previously-fullscreen window a few
        // seconds into the next launch (its own Spaces/saved-state restoration),
        // independent of Chromium's restored show-state and the window's
        // `isRestorable` — leaving restored windows fullscreen (and the reconcile
        // then orphans empty fullscreen Spaces). Chromium owns tab/session
        // restore and Phi owns window frame/Space affinity, so AppKit's
        // window-state restoration is redundant here; turning it off makes
        // restored windows come back as normal windows. Set in `init` (before
        // `applicationWillFinishLaunching`) so it lands before AppKit reads it.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        ChromiumLauncher.sharedInstance().bridge?.applicationDidFinishLaunching(notification)

#if !DEBUG
        setupSparkle()
#endif
        setupKinfisherCache()

        MemoryUsageMonitor.shared.start()

        DefaultExtensionManifestWriter.start()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(phiWillTryToTerminateApplicationNotification(_:)),
                                               name: Notification.Name("PhiWillTryToTerminateApplicationNotification"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(refreshSpacesMenuVisibility),
                                               name: .activeBrowserWindowDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(refreshBookmarksMenuVisibility),
                                               name: .activeBrowserWindowDidChange,
                                               object: nil)
        
        Task { @MainActor in
            OnboardingController.shared.showIfNeeded()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        bindChromiumBridgeIfNeeded()

        // Register defaults before any settings are read.
        UserDefaultsRegistration.registerDefaults()

        // Phi is local-only: one stable account owns all Swift-side browser
        // state, with no authentication or remote identity lifecycle.
        AccountController.shared.account = Account.defaultAccount

        setupLogging()
        AppLogInfo("------------------------------  Starting: \(Self.makeClientString())  ------------------------------")
        recordLaunchVersion()

        chromiumBridge?.applicationWillFinishLaunching(notification)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        coldOpenURLForwardWorkItem?.cancel()
        coldOpenURLForwardWorkItem = nil
        AppLogInfo("-------applicationWillTerminate----")
        MemoryUsageMonitor.shared.stop()
        if let chromiumBridge {
            chromiumBridge.applicationWillTerminate(notification)
        } else {
            AppLogWarn("[AppController] applicationWillTerminate: chromium bridge not cached; using launcher fallback")
            ChromiumLauncher.sharedInstance().bridge?.applicationWillTerminate(notification)
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLogInfo("-----------------------------  Quitting: \(Self.makeClientString()) ------------------------------")
        // Note: on Cmd+Q this fires AFTER Chromium's window teardown; the restore
        // snapshot is frozen earlier, in phiWillTryToTerminateApplicationNotification.
        // Re-assert here as a backstop for any quit path that reaches this hook.
        SpaceManager.shared.markTerminating()
        // A bookmark-export write may still be running on a background queue
        // (slow network/cloud destination); dying now would silently drop a
        // save the user already confirmed. The write's completion handler
        // resumes termination via reply(toApplicationShouldTerminate:).
        if Self.inFlightBookmarkExportWrites > 0 {
            Self.bookmarkExportTerminationPending = true
            return .terminateLater
        }
        return .terminateNow
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // FIXME: Closing the final window via the title-bar button can bypass Chromium's tab-close
        // notifications. We likely need a more explicit cleanup and restore strategy here.
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if SpaceManager.shared.reopenOnPersistedSpaceIfWindowless() {
            return true
        }
        let handled = ChromiumLauncher.sharedInstance().bridge?.applicationShouldHandleReopen(sender, hasVisibleWindows: hasVisibleWindows) ?? false
        SpaceManager.shared.reconcileSlotVisibilityAfterReopen()
        return handled
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        ChromiumLauncher.sharedInstance().bridge?.applicationDockMenu(sender)
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first, DeeplinkHandler.handle(url) {
            return
        }
        scheduleForwardOpenURLsToChromium(application: application, urls: urls)
    }

    /// Forwards `application(_:open:)` URLs to Chromium. Cold launch defers ~600ms so
    /// `StartupBrowserCreator` / session restore can register a browser before
    /// `PhiOpenUrlsInBrowser` would otherwise call `Browser::Create` again.
    private func scheduleForwardOpenURLsToChromium(application: NSApplication, urls: [URL]) {
        let manager = MainBrowserWindowControllersManager.shared
        if manager.getFirstAvailableWindowId() != nil {
            let urlsToForward = pendingColdOpenForwardURLs + urls
            pendingColdOpenForwardURLs.removeAll()
            coldOpenURLForwardWorkItem?.cancel()
            coldOpenURLForwardWorkItem = nil
            forwardOpenURLsToChromium(application: application, urls: urlsToForward, label: "immediate")
            return
        }

        pendingColdOpenForwardURLs.append(contentsOf: urls)
        guard coldOpenURLForwardWorkItem == nil else {
            AppLogDebug("[coldopen] urls appended to pending bridge forward queue")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coldOpenURLForwardWorkItem = nil
            let urlsToForward = self.pendingColdOpenForwardURLs
            self.pendingColdOpenForwardURLs.removeAll()
            self.forwardOpenURLsToChromium(application: application, urls: urlsToForward, label: "deferred-600ms")
        }
        coldOpenURLForwardWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coldOpenURLForwardDelay, execute: work)
        AppLogDebug("[coldopen] urls call bridge scheduled in \(Self.coldOpenURLForwardDelay)s")
    }

    private func forwardOpenURLsToChromium(application: NSApplication, urls: [URL], label: String) {
        AppLogDebug("[coldopen] urls call bridge (\(label))")
        ChromiumLauncher.sharedInstance().bridge?.application(application, open: urls)
    }
    
    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        return ChromiumLauncher.sharedInstance().bridge?.application(application, willContinueUserActivityWithType: userActivityType) ?? false
    }
    
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        return ChromiumLauncher.sharedInstance().bridge?.application(application, continue: userActivity, restorationHandler: restorationHandler) ?? false
    }
    
    @MainActor
    @objc func phiWillTryToTerminateApplicationNotification(_ notification: Notification) {
        // Posted (synchronously, main thread) by phi_app_controller_mac.mm's
        // -tryToTerminateApplication: BEFORE chrome::CloseAllBrowsers() tears the
        // windows down. This is the only quit signal that fires ahead of that
        // teardown cascade (the AppKit applicationWillTerminate hook runs after
        // it). Freeze the restore snapshot here so the closing windows can't
        // drain it — the next launch then regroups restored windows into their
        // slots and re-enters fullscreen.
        SpaceManager.shared.markTerminating()
    }

    private func bindChromiumBridgeIfNeeded() {
        if chromiumBridge == nil {
            chromiumBridge = ChromiumLauncher.sharedInstance().bridge
        }
    }

}

extension AppController {
    static var clientString: String?
    static func makeClientString() -> String {
        if clientString != nil { return clientString! }

        let preferredLang: String = {
            if let id = Locale.preferredLanguages.first, let lang = id.split(separator: "-").first {
                return String(lang)
            }
            return Locale.current.language.languageCode?.identifier ?? "en"
        }()

        let country = (Locale.current as NSLocale).object(forKey: .countryCode) as? String ?? "US"
        let localeStr = "\(preferredLang)-\(country)"

        let info = Bundle.main.infoDictionary ?? [:]
        let buildVersion = info["CFBundleVersion"] as? String ?? "0"
        let marketingVersion = info["CFBundleShortVersionString"] as? String ?? "0"

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let marketingWithChannel = marketingVersion

        let name = "Phi /\(buildVersion) \(marketingWithChannel) (\(localeStr)); MacOS/\(osVersion);"
        clientString = name
        return name
    }
}

extension AppController {
    private func setupKinfisherCache() {
        FaviconDataProvider.setupCache()
    }
}
