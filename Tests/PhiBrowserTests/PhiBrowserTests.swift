// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import AppKit
@testable import Phi

final class PhiBrowserTests: XCTestCase {
    func testLuaNormalizesLegacyLayoutChoicesToPerformance() {
        let defaults = UserDefaults.standard
        let key = PhiPreferences.GeneralSettings.layoutModeKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set(LayoutMode.comfortable.rawValue, forKey: key)

        XCTAssertEqual(PhiPreferences.GeneralSettings.loadLayoutMode(), .performance)
        XCTAssertEqual(defaults.string(forKey: key), LayoutMode.performance.rawValue)
        XCTAssertEqual(LayoutMode.allCases, [.performance])
    }

    func testSidebarPositionDefaultsLeftAndPersistsRight() {
        let defaults = UserDefaults.standard
        let key = PhiPreferences.GeneralSettings.sidebarPositionKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadSidebarPosition(), .left)

        PhiPreferences.GeneralSettings.saveSidebarPosition(.right)
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadSidebarPosition(), .right)
    }

    func testCopyURLShortcutIsCustomizableFromEditShortcuts() {
        XCTAssertEqual(
            Shortcuts.DefaultShortcuts[.PHI_COPY_URL],
            ShortcutsKey(characters: "c", modifiers: [.command, .shift])
        )
        XCTAssertTrue(Shortcuts.Group.edit.commands.contains(.PHI_COPY_URL))
        XCTAssertEqual(CommandWrapper.PHI_COPY_URL.displayName, "Copy URL")
    }

    func testCopyURLShortcutKeycapsMatchMacModifierOrder() {
        let shortcut = ShortcutsKey(characters: "c", modifiers: [.command, .shift])

        XCTAssertEqual(shortcut.keycapTokens, ["⇧", "⌘", "C"])
    }

    func testShortcutKeycapsUseReadableSpecialKeySymbols() {
        let shortcut = ShortcutsKey(
            characters: "\u{F702}",
            modifiers: [.control, .option]
        )

        XCTAssertEqual(shortcut.keycapTokens, ["⌃", "⌥", "←"])
        XCTAssertEqual(shortcut.displayString, "⌥⌃←")
    }

    func testBuiltInThemePaletteUsesRequestedColorsWithZincAsDefault() {
        XCTAssertEqual(Theme.default, Theme.zinc)
        XCTAssertEqual(Theme.builtInThemes.map(\.id), ["zinc", "pink", "yellow", "green"])

        assertColor(Theme.zinc.color(for: .themeColor, appearance: .light), equals: NSColor(hex: 0x71717A))
        assertColor(Theme.pink.color(for: .themeColor, appearance: .light), equals: NSColor(hex: 0xEF476F))
        assertColor(Theme.yellow.color(for: .themeColor, appearance: .light), equals: NSColor(hex: 0xFFD166))
        assertColor(Theme.green.color(for: .themeColor, appearance: .light), equals: NSColor(hex: 0x06D6A0))

        for theme in Theme.builtInThemes {
            assertColor(
                theme.color(for: .windowOverlayBackground, appearance: .dark),
                equals: NSColor(hex: 0x171717)
            )
            assertColor(
                theme.color(for: .windowBackground, appearance: .dark),
                equals: NSColor(hex: 0x0A0A0A)
            )
        }
    }

    func testRemovedThemeIdentifiersMigrateToCurrentPalette() {
        XCTAssertEqual(Theme.migratedBuiltInThemeId("pure"), Theme.zinc.id)
        XCTAssertEqual(Theme.migratedBuiltInThemeId("coral"), Theme.zinc.id)
        XCTAssertEqual(Theme.migratedBuiltInThemeId("amber"), Theme.zinc.id)
        XCTAssertEqual(Theme.migratedBuiltInThemeId("mint"), Theme.zinc.id)
    }

    @MainActor
    func testBrowserThemeContextPublishesThemeChangesForSameThemeIdentifier() {
        let initialTheme = Theme(id: "browser-context-same-id", name: "Context")
        initialTheme.setColor(
            light: NSColor(hex: 0x445566, alpha: 0.40),
            dark: NSColor(hex: 0x112233, alpha: 0.80),
            for: .windowOverlayBackground
        )

        let context = BrowserThemeContext(
            configuration: BrowserThemeConfiguration(
                currentTheme: initialTheme,
                userAppearanceChoice: .light,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        )

        var observedThemeColors: [NSColor] = []
        let subscription = context.subscribe { theme, appearance in
            observedThemeColors.append(theme.color(for: .themeColor, appearance: appearance))
        }

        let updatedTheme = Theme(id: initialTheme.id, name: initialTheme.name)
        updatedTheme.setColor(ColorPair(NSColor(hex: 0xEF476F)), for: .themeColor)
        context.setTheme(updatedTheme)

        _ = subscription

        XCTAssertEqual(observedThemeColors.count, 2)
        assertColor(observedThemeColors[1], equals: NSColor(hex: 0xEF476F))
    }

    func testBookmarkMainMenuItemRoutingKeepsChromiumBookmarksItemUntouched() {
        let action = BookmarkMainMenuItemRouting.action(
            title: "Bookmarks",
            tag: 40029
        )

        XCTAssertEqual(
            action,
            .hideSystemItem,
            "The Chromium-owned Bookmarks menu item must stay discoverable by IDC_BOOKMARKS_MENU so AppController should only hide it instead of repurposing it as the native custom Bookmarks menu."
        )
    }

    func testBookmarkMainMenuItemRoutingRecognizesCustomBookmarksItem() {
        let action = BookmarkMainMenuItemRouting.action(
            title: "Bookmarks",
            tag: AppController.bookmarksMenuItemTag
        )

        XCTAssertEqual(
            action,
            .configureCustomItem,
            "The native Phi Bookmarks item should be the only menu item that gets reconfigured and rebuilt."
        )
    }

    func testBookmarkMenuContentBuilderAddsBookmarkThisTabAndRecursiveBookmarks() {
        let rootBookmark = Bookmark(title: "Lua", url: "https://example.com")
        let folder = Bookmark(folderTitle: "Favorites")
        let childBookmark = Bookmark(title: "Docs", url: "https://example.com/docs")
        folder.addChild(childBookmark)
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [rootBookmark, folder],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: true,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertEqual(
            menu.items.first?.title,
            NSLocalizedString("Bookmark This Tab...", comment: "Bookmarks menu - Menu item to add or edit a bookmark for the currently focused tab")
        )
        XCTAssertEqual(menu.items.first?.tag, CommandWrapper.IDC_BOOKMARK_THIS_TAB.rawValue)
        XCTAssertEqual(
            menu.items.dropFirst().first?.title,
            NSLocalizedString("Bookmark All Tabs...", comment: "Bookmarks menu - Menu item to add bookmarks for all currently open tabs in the active window")
        )
        XCTAssertEqual(menu.items.dropFirst().first?.tag, CommandWrapper.IDC_BOOKMARK_ALL_TABS.rawValue)
        XCTAssertTrue(
            menu.items.first?.isEnabled == true,
            "The Bookmarks menu should enable the Bookmark This Tab item when the active window has a focusable tab URL."
        )
        XCTAssertTrue(menu.items.dropFirst(2).first?.isSeparatorItem == true)
        XCTAssertEqual(
            menu.items.dropFirst(3).first?.title,
            NSLocalizedString("Export Bookmarks...", comment: "Bookmarks menu - Menu item to export the current Space's bookmarks to an HTML file")
        )
        XCTAssertTrue(menu.items.dropFirst(4).first?.isSeparatorItem == true)
        XCTAssertEqual(menu.items.dropFirst(5).map(\.title), ["Lua", "Favorites"])
        XCTAssertEqual(menu.items.last?.submenu?.items.map(\.title), ["Docs"])
    }

    func testBookmarkMenuContentBuilderDisablesBookmarkThisTabWithoutFocusedTab() {
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [],
            canBookmarkCurrentTab: false,
            canBookmarkAllTabs: false,
            canExportBookmarks: false,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertFalse(
            menu.items.first?.isEnabled == true,
            "The Bookmarks menu should disable the Bookmark This Tab item when there is no focused tab with a bookmarkable URL."
        )
        XCTAssertFalse(
            menu.items.dropFirst().first?.isEnabled == true,
            "The Bookmarks menu should disable the Bookmark All Tabs item when the active window does not have more than one bookmarkable open tab."
        )
        XCTAssertFalse(
            menu.items.dropFirst(3).first?.isEnabled == true,
            "The Bookmarks menu should disable the Export Bookmarks item when the current Space has no bookmarks to export."
        )
        XCTAssertEqual(menu.items.count, 4)
    }

    func testBookmarkMenuContentBuilderShowsDisabledEmptyItemForEmptyFolders() {
        let emptyFolder = Bookmark(folderTitle: "Empty Folder")
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [emptyFolder],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: true,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        let folderItem = menu.items[5]
        let emptyItem = try? XCTUnwrap(folderItem.submenu?.items.first)

        XCTAssertEqual(folderItem.title, "Empty Folder")
        XCTAssertEqual(
            emptyItem?.title,
            NSLocalizedString("Empty", comment: "Bookmarks menu - Disabled placeholder item shown when a bookmark folder has no child bookmarks")
        )
        XCTAssertFalse(
            emptyItem?.isEnabled == true,
            "Empty bookmark folders should show a disabled placeholder item so the submenu still renders a stable empty state."
        )
    }

    func testBookmarkMenuContentBuilderDisablesBookmarkAllTabsWithoutEnoughTabs() {
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: false,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertEqual(menu.items[1].tag, CommandWrapper.IDC_BOOKMARK_ALL_TABS.rawValue)
        XCTAssertFalse(
            menu.items[1].isEnabled,
            "Bookmark All Tabs should be disabled unless the active window has more than one bookmarkable open tab."
        )
    }

    @MainActor
    func testExtensionPopupAnchorUsesPrimaryScreenHeightForChromiumFlip() {
        let point = NSPoint(x: 240, y: 320)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumPoint = ExtensionPopupAnchor.chromiumScreenPoint(
            from: point,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(chromiumPoint.x, 240)
        XCTAssertEqual(
            chromiumPoint.y,
            580,
            "Extension popup anchors must flip against the primary display height so Swift matches Chromium's global screen coordinates."
        )
    }

    @MainActor
    func testExtensionPopupAnchorPreservesLegitimateNegativeChromiumY() {
        let point = NSPoint(x: 120, y: 960)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumPoint = ExtensionPopupAnchor.chromiumScreenPoint(
            from: point,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(
            chromiumPoint.y,
            -60,
            "Points above the primary display should remain negative after the AppKit-to-Chromium flip."
        )
    }

    func testOmniBoxSearchCoordinatorSuppressesOnlyTheNextAutomaticSearchAfterPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "https://example.com", minInputLength: 1)

        XCTAssertFalse(
            coordinator.shouldPerformAutomaticSearch(for: "https://example.com", minInputLength: 1),
            "Prefilling the current tab URL should not immediately trigger a duplicate automatic search."
        )
        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "https://example.com/path", minInputLength: 1),
            "Only the next automatic search should be suppressed so later edits still update suggestions."
        )
    }

    func testOmniBoxSearchCoordinatorAcceptsResponsesMatchingTheLatestQuery() {
        let coordinator = OmniBoxSearchCoordinator()

        _ = coordinator.beginRequest(query: "phi", source: .inputChange)
        _ = coordinator.beginRequest(query: "phibrowser", source: .openPrefill)

        XCTAssertFalse(
            coordinator.shouldAcceptResponse(forQuery: "phi"),
            "Stale suggestion responses should be ignored once a newer query has been issued."
        )
        XCTAssertTrue(
            coordinator.shouldAcceptResponse(forQuery: "phibrowser"),
            "Responses matching the latest query should be applied to the UI."
        )
    }

    func testOmniBoxSearchCoordinatorAcceptsStreamedResponsesForTheSameQuery() {
        let coordinator = OmniBoxSearchCoordinator()

        _ = coordinator.beginRequest(query: "phi", source: .inputChange)

        XCTAssertTrue(coordinator.shouldAcceptResponse(forQuery: "phi"))
        // Chromium streams multiple updates per request as providers respond, every
        // subsequent emission for the same query must still be applied.
        XCTAssertTrue(coordinator.shouldAcceptResponse(forQuery: "phi"))
    }

    func testOmniBoxSearchCoordinatorDoesNotArmSuppressionForEmptyPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "", minInputLength: 1)

        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "g", minInputLength: 1),
            "An empty prefill should not consume the user's first real search edit."
        )
    }

    func testOmniBoxTraceSessionFormatsReadableElapsedLogMessages() {
        var ticks: [UInt64] = [1_000_000_000, 1_125_000_000]
        let session = OmniBoxTraceSession(
            trigger: "address-bar",
            timeProvider: { ticks.removeFirst() }
        )

        let message = session.message(for: "request-start", details: "queryLength=12")

        XCTAssertTrue(message.contains("[OmniboxTrace]"))
        XCTAssertTrue(message.contains("trigger=address-bar"))
        XCTAssertTrue(message.contains("stage=request-start"))
        XCTAssertTrue(message.contains("elapsed=125.0ms"))
        XCTAssertTrue(message.contains("queryLength=12"))
    }

    func testHoverableButtonNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let button = HoverableButtonNSView(
            config: HoverableButtonConfig(title: "Test", displayMode: .titleOnly),
            action: {}
        )
        var didInvokeSecondaryAction = false
        button.secondaryAction = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        button.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Pinned extension buttons should route right clicks through their secondary action."
        )
    }

    func testHoverableViewInvokesSecondaryClickActionOnRightMouseDown() throws {
        let view = HoverableView()
        var didInvokeSecondaryClick = false
        view.secondaryClickAction = {
            didInvokeSecondaryClick = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryClick,
            "Sidebar pinned extension items should route right clicks through their secondary click action."
        )
    }

    func testSecondaryClickPassthroughNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let view = SecondaryClickPassthroughNSView()
        var didInvokeSecondaryAction = false
        view.onSecondaryClick = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Popover extension items should route right clicks through the shared secondary click passthrough."
        )
    }

    func testSecondaryClickContainerNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let view = SecondaryClickContainerNSView()
        var didInvokeSecondaryAction = false
        view.onSecondaryClick = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Popover grid items should handle right clicks through their dedicated AppKit container."
        )
    }

    private func assertColor(
        _ actual: NSColor,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualColor = actual.usingColorSpace(.extendedSRGB) ?? actual
        let expectedColor = expected.usingColorSpace(.extendedSRGB) ?? expected

        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}

private final class BookmarkMenuTestTarget: NSObject {
    @objc func menuAction(_ sender: Any?) {}
}
