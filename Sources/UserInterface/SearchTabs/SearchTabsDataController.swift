// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@MainActor
final class SearchTabsDataController {
    private weak var browserState: BrowserState?
    private let chromiumProvider: SearchTabsChromiumProvider

    init(browserState: BrowserState) {
        self.browserState = browserState
        self.chromiumProvider = SearchTabsChromiumProvider()
    }

    init(browserState: BrowserState, chromiumProvider: SearchTabsChromiumProvider) {
        self.browserState = browserState
        self.chromiumProvider = chromiumProvider
    }

    init(browserState: BrowserState?, chromiumProvider: SearchTabsChromiumProvider) {
        self.browserState = browserState
        self.chromiumProvider = chromiumProvider
    }

    func snapshot(query: String) -> SearchTabsSnapshot {
        guard let state = browserState else {
            return SearchTabsSnapshot(
                query: query,
                profileId: LocalStore.defaultProfileId,
                windowId: 0,
                generatedAt: Date(),
                items: []
            )
        }

        let normalizedQuery = SearchTabsQueryMatcher.normalizedQuery(query)
        let nativeProvider = SearchTabsNativeProvider(browserState: state)
        return SearchTabsAggregator.aggregate(
            query: query,
            profileId: state.profileId,
            windowId: state.windowId,
            chromium: chromiumProvider.snapshot(windowId: state.windowId),
            native: nativeProvider.snapshot(includeBookmarkRoot: normalizedQuery.isEmpty)
        )
    }
}
