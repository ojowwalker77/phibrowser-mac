// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class SearchTabsDataTests: XCTestCase {
    func testQueryMatcherRanksTitlePrefixBeforeTitleContainsAndURLContains() {
        let prefix = SearchTabsQueryMatcher.match(
            query: "git",
            primaryTitle: "GitHub",
            primaryURL: "https://example.com",
            secondaryTitle: nil,
            secondaryURL: nil
        )
        let titleContains = SearchTabsQueryMatcher.match(
            query: "hub",
            primaryTitle: "GitHub",
            primaryURL: "https://example.com",
            secondaryTitle: nil,
            secondaryURL: nil
        )
        let hostContains = SearchTabsQueryMatcher.match(
            query: "github",
            primaryTitle: "Docs",
            primaryURL: "https://github.com/features/copilot",
            secondaryTitle: nil,
            secondaryURL: nil
        )
        let pathContains = SearchTabsQueryMatcher.match(
            query: "copilot",
            primaryTitle: "Docs",
            primaryURL: "https://github.com/features/copilot",
            secondaryTitle: nil,
            secondaryURL: nil
        )

        XCTAssertGreaterThan(prefix?.score ?? 0, titleContains?.score ?? 0)
        XCTAssertGreaterThan(titleContains?.score ?? 0, hostContains?.score ?? 0)
        XCTAssertGreaterThan(hostContains?.score ?? 0, pathContains?.score ?? 0)
        XCTAssertEqual(prefix?.matchedFields, [.title])
        XCTAssertEqual(hostContains?.matchedFields, [.host])
        XCTAssertEqual(pathContains?.matchedFields, [.url])
    }

    func testQueryMatcherSearchesSecondaryPaneForNativeSplitEntries() {
        let match = SearchTabsQueryMatcher.match(
            query: "calendar",
            primaryTitle: "Mail",
            primaryURL: "https://mail.example",
            secondaryTitle: "Calendar",
            secondaryURL: "https://calendar.example"
        )

        XCTAssertEqual(match?.score, SearchTabsQueryMatcher.titlePrefixScore)
        XCTAssertEqual(match?.matchedFields, [.secondaryTitle])
    }

    func testQueryMatcherReturnsNilForNonMatchingQuery() {
        let match = SearchTabsQueryMatcher.match(
            query: "figma",
            primaryTitle: "Mail",
            primaryURL: "https://mail.example",
            secondaryTitle: nil,
            secondaryURL: nil
        )

        XCTAssertNil(match)
    }
}
