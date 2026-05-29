// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

extension BrowserState {
    var activeGroupOverviewToken: String? {
        groupOverviewState?.groupToken
    }

    @MainActor
    func showGroupOverview(token: String) {
        guard groups[token] != nil,
              normalTabs.contains(where: { $0.groupToken == token }) else {
            clearGroupOverview()
            return
        }
        groupOverviewState = GroupOverviewState(groupToken: token)
    }

    @MainActor
    func clearGroupOverview() {
        groupOverviewState = nil
    }

    @MainActor
    func clearGroupOverview(ifToken token: String) {
        guard activeGroupOverviewToken == token else { return }
        clearGroupOverview()
    }

    func isShowingGroupOverview(for token: String) -> Bool {
        activeGroupOverviewToken == token
    }

    @MainActor
    func validateActiveGroupOverview() {
        guard let token = activeGroupOverviewToken else { return }
        guard groups[token] != nil,
              normalTabs.contains(where: { $0.groupToken == token }) else {
            clearGroupOverview()
            return
        }
    }

    @MainActor
    func createTabInCurrentOverviewGroup(url: String) {
        guard let token = activeGroupOverviewToken,
              groups[token] != nil else { return }
        let targetIndex = overviewGroupInsertionIndex(token: token, groupIndex: 0)
        AppLogDebug(
            "[TAB_GROUPS] overview createTab windowId=\(windowId) " +
            "token=\(token) groupIndex=0 targetIndex=\(targetIndex) " +
            "focusAfterCreate=true url=\(url)"
        )
        scheduleNextNormalTabInsertion(at: targetIndex,
                                       syncChromiumOrder: true,
                                       expectedGroupToken: token)
        clearGroupOverview()
        ChromiumLauncher.sharedInstance().bridge?.createTabInGroup(
            withWindowId: Int64(windowId),
            tokenHex: token,
            url: url,
            groupIndex: 0,
            focusAfterCreate: true
        )
    }

    @MainActor
    func createNewTabAtEndOfCurrentOverviewGroup() {
        guard let token = activeGroupOverviewToken,
              groups[token] != nil else { return }
        let memberCount = normalTabs.lazy.filter { $0.groupToken == token }.count
        let targetIndex = overviewGroupInsertionIndex(token: token, groupIndex: memberCount)
        AppLogDebug(
            "[TAB_GROUPS] overview createNewTab windowId=\(windowId) " +
            "token=\(token) groupIndex=\(memberCount) targetIndex=\(targetIndex) " +
            "focusAfterCreate=true"
        )
        scheduleNextNormalTabInsertion(at: targetIndex,
                                       syncChromiumOrder: true,
                                       expectedGroupToken: token)
        clearGroupOverview()
        ChromiumLauncher.sharedInstance().bridge?.createTabInGroup(
            withWindowId: Int64(windowId),
            tokenHex: token
        )
    }

    private func overviewGroupInsertionIndex(token: String, groupIndex: Int) -> Int {
        let memberIndices = normalTabs.enumerated()
            .compactMap { index, tab in tab.groupToken == token ? index : nil }
        guard let first = memberIndices.first else { return 0 }
        guard groupIndex < memberIndices.count else {
            return (memberIndices.last ?? first) + 1
        }
        return memberIndices[groupIndex]
    }
}
