# Split View Shared Chat Tab Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make a split view bind to exactly one shared AI Chat tab so switching the active pane never switches the chat tab.

**Architecture:** Keep `aiChatTabs` as the single source of truth. Add a chat-only resolver `chatIdentifier(for:)` on `BrowserState` that, for split panes, derives one shared key from `aiChatTabs`. Reconcile at split creation (close the loser when both panes have a chat), migrate to the survivor on pane close, and have `EmbeddedChatViewController` re-resolve on `$splits` changes. `getTabIdentifier` (webContent-VC keying) is unchanged.

**Tech Stack:** Swift, AppKit, Combine, XCTest (`@testable import Phi`), Xcode build via Xcode MCP.

Design doc: `docs/plans/2026-06-03-splitview-shared-chat-tab-design.md`

---

## Conventions

- Build/test via Xcode MCP tools where possible; CLI fallback:
  `xcodebuild test -scheme Phi -destination 'platform=macOS' -only-testing:PhiBrowserTests/SplitChatBindingTests`
- All new comments in English. Log prefix `🤖 [AIChat]` / `🔄 [AIChat]`.
- Do NOT commit unless explicitly instructed (project git rule). The "Commit"
  steps below are gated on the user asking for a commit.

---

### Task 1: Chat identifier resolver

**Files:**
- Modify: `Sources/States/BrowserState.swift` (near `getTabIdentifier`, ~line 242)
- Test: `Tests/PhiBrowserTests/SplitChatBindingTests.swift` (create)

**Step 1: Write the failing test**

Create `Tests/PhiBrowserTests/SplitChatBindingTests.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class SplitChatBindingTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func seed(_ state: BrowserState, guids: [Int]) {
        state.tabs = guids.map { Tab(guid: $0, url: "https://e\($0).example", isActive: false, index: 0) }
        state.updateNormalTabs()
    }

    private func makeChatTab(guid: Int) -> Tab {
        Tab(guid: guid, url: "chrome-extension://x/index.html", isActive: false, index: 0)
    }

    private func splitGroup(_ p: Int, _ s: Int) -> SplitGroup {
        SplitGroup(id: "split-\(p)-\(s)", primaryTabId: p, secondaryTabId: s,
                   layout: .vertical, ratio: 0.5)
    }

    func testResolverOutsideSplitReturnsOwnIdentifier() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        XCTAssertEqual(state.chatIdentifier(for: state.tabs[0]),
                       state.getTabIdentifier(for: state.tabs[0]))
    }

    func testResolverWhenOnlyOnePaneHasChatReturnsThatPane() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.splits = [splitGroup(1, 2)]
        let id1 = state.getTabIdentifier(for: state.tabs[0])
        state.aiChatTabs[id1] = makeChatTab(guid: 100)

        XCTAssertEqual(state.chatIdentifier(for: state.tabs[0]), id1)
        XCTAssertEqual(state.chatIdentifier(for: state.tabs[1]), id1)
    }

    func testResolverWhenNoPaneHasChatReturnsForegroundPane() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.splits = [splitGroup(1, 2)]
        state.focuseTab(state.tabs[1])

        let id2 = state.getTabIdentifier(for: state.tabs[1])
        XCTAssertEqual(state.chatIdentifier(for: state.tabs[0]), id2)
        XCTAssertEqual(state.chatIdentifier(for: state.tabs[1]), id2)
    }
}
```

**Step 2: Run test to verify it fails**

Run the `SplitChatBindingTests` suite. Expected: FAILS to compile (`chatIdentifier` undefined).

**Step 3: Write minimal implementation**

In `BrowserState.swift`, right after `getTabIdentifier(for:)`:

```swift
/// Resolves the identifier under which a tab's AI Chat tab is keyed.
/// For tabs inside a split, both panes resolve to a single shared key so the
/// split shares exactly one chat tab and switching the active pane does not
/// switch the chat. Outside a split, falls back to the per-tab identifier.
func chatIdentifier(for tab: Tab) -> String {
    guard let group = splitGroup(forTabId: tab.guid),
          let primary = tabs.first(where: { $0.guid == group.primaryTabId }),
          let secondary = tabs.first(where: { $0.guid == group.secondaryTabId }) else {
        return getTabIdentifier(for: tab)
    }
    let primaryId = getTabIdentifier(for: primary)
    let secondaryId = getTabIdentifier(for: secondary)
    if aiChatTabs[primaryId] != nil { return primaryId }
    if aiChatTabs[secondaryId] != nil { return secondaryId }
    if let focused = focusingTab, focused.guid == secondary.guid { return secondaryId }
    return primaryId
}
```

**Step 4: Run test to verify it passes**

Run `SplitChatBindingTests`. Expected: PASS (3 tests).

**Step 5: Commit** (only if user asks)

```bash
git add Sources/States/BrowserState.swift Tests/PhiBrowserTests/SplitChatBindingTests.swift
git commit -m "feat: add shared chat identifier resolver for split view"
```

---

### Task 2: Split-creation reconcile (close the loser)

**Files:**
- Modify: `Sources/States/BrowserState+Split.swift` (add method; call in `handleSplitCreated`)
- Test: `Tests/PhiBrowserTests/SplitChatBindingTests.swift`

**Step 1: Write the failing test**

Append to `SplitChatBindingTests`:

```swift
func testReconcileBothHaveChatKeepsForegroundClosesOther() throws {
    let state = try makeState()
    seed(state, guids: [1, 2])
    let id1 = state.getTabIdentifier(for: state.tabs[0])
    let id2 = state.getTabIdentifier(for: state.tabs[1])
    state.aiChatTabs[id1] = makeChatTab(guid: 100)
    state.aiChatTabs[id2] = makeChatTab(guid: 200)
    let group = splitGroup(1, 2)
    state.splits = [group]
    state.focuseTab(state.tabs[1]) // secondary is foreground

    state.reconcileSplitChatBinding(group)

    XCTAssertNil(state.aiChatTabs[id1])              // loser closed
    XCTAssertNotNil(state.aiChatTabs[id2])           // foreground kept
    XCTAssertEqual(state.chatIdentifier(for: state.tabs[0]), id2)
}

func testReconcileSinglePaneChatIsNoop() throws {
    let state = try makeState()
    seed(state, guids: [1, 2])
    let id1 = state.getTabIdentifier(for: state.tabs[0])
    state.aiChatTabs[id1] = makeChatTab(guid: 100)
    let group = splitGroup(1, 2)
    state.splits = [group]

    state.reconcileSplitChatBinding(group)

    XCTAssertNotNil(state.aiChatTabs[id1])
}
```

**Step 2: Run test to verify it fails**

Expected: FAILS to compile (`reconcileSplitChatBinding` undefined).

**Step 3: Write minimal implementation**

In `BrowserState+Split.swift`, add (internal, not private, so tests reach it):

```swift
/// Reconcile a freshly-created split so it shares exactly one chat tab.
/// Principle 1: a pane that already has a chat tab keeps it (resolver handles
/// it; no action needed here). Principle 2: when BOTH panes have a chat tab,
/// keep the foreground pane's and close the other (a split owns one chat tab).
@MainActor
func reconcileSplitChatBinding(_ group: SplitGroup) {
    guard let primary = tabs.first(where: { $0.guid == group.primaryTabId }),
          let secondary = tabs.first(where: { $0.guid == group.secondaryTabId }) else {
        return
    }
    let primaryId = getTabIdentifier(for: primary)
    let secondaryId = getTabIdentifier(for: secondary)
    guard aiChatTabs[primaryId] != nil, aiChatTabs[secondaryId] != nil else {
        return
    }
    let keepSecondary = focusingTab?.guid == secondary.guid
    let dropId = keepSecondary ? primaryId : secondaryId
    closeAIChatTab(for: dropId)
}
```

Then call it at the end of `handleSplitCreated`, after the group is stored in
`splits` (after the `enforceSplitAdjacency()` block, before/after the
`needsReverse` task is fine — use the stored `group`):

```swift
        reconcileSplitChatBinding(group)
```

**Step 4: Run test to verify it passes**

Run `SplitChatBindingTests`. Expected: PASS (5 tests total).

**Step 5: Commit** (only if user asks)

```bash
git add Sources/States/BrowserState+Split.swift Tests/PhiBrowserTests/SplitChatBindingTests.swift
git commit -m "feat: close the losing chat tab when both split panes have one"
```

---

### Task 3: Migrate chat tab to survivor on pane close

**Files:**
- Modify: `Sources/States/BrowserState.swift` (`migrateAIChatTab` overload; `closeTab` ~line 1307)
- Test: `Tests/PhiBrowserTests/SplitChatBindingTests.swift`

**Step 1: Write the failing test**

Append:

```swift
func testMigrateHelperMovesChatKey() throws {
    let state = try makeState()
    seed(state, guids: [1, 2])
    let id1 = state.getTabIdentifier(for: state.tabs[0])
    let id2 = state.getTabIdentifier(for: state.tabs[1])
    let chat = makeChatTab(guid: 100)
    state.aiChatTabs[id1] = chat

    state.migrateAIChatTab(fromIdentifier: id1, toIdentifier: id2)

    XCTAssertNil(state.aiChatTabs[id1])
    XCTAssertTrue(state.aiChatTabs[id2] === chat)
}
```

**Step 2: Run test to verify it fails**

Expected: FAILS to compile (overload undefined).

**Step 3: Write minimal implementation**

In `BrowserState.swift`, near the existing private `migrateAIChatTab(for:toNewIdentifier:)`, add an internal explicit-key overload:

```swift
/// Move the shared chat tab from one identifier to another (e.g. when a split
/// pane closes and the chat tab must follow the surviving pane).
func migrateAIChatTab(fromIdentifier oldId: String, toIdentifier newId: String) {
    guard oldId != newId, let aiChatTab = aiChatTabs.removeValue(forKey: oldId) else { return }
    aiChatTabs[newId] = aiChatTab
    AppLogInfo("🔄 [AIChat] Migrated split chat tab from '\(oldId)' to '\(newId)'")
}
```

Then modify `closeTab`'s normal-tab AI-chat close (currently lines ~1307-1308):

```swift
        let identifier = getTabIdentifier(for: closedTab)
        if let group = splitGroup(forTabId: closedTab.guid),
           let partnerId = group.partnerTabId(of: closedTab.guid),
           let survivor = tabs.first(where: { $0.guid == partnerId }),
           aiChatTabs[identifier] != nil {
            // Closing pane owns the split's shared chat tab → hand it to the
            // surviving pane instead of closing it (follow survivor).
            migrateAIChatTab(fromIdentifier: identifier,
                             toIdentifier: getTabIdentifier(for: survivor))
        } else {
            closeAIChatTab(for: identifier)
        }
```

**Step 4: Run test to verify it passes**

Run `SplitChatBindingTests`. Expected: PASS (6 tests total).

**Step 5: Commit** (only if user asks)

```bash
git add Sources/States/BrowserState.swift Tests/PhiBrowserTests/SplitChatBindingTests.swift
git commit -m "feat: keep split chat tab on surviving pane when a pane closes"
```

---

### Task 4: EmbeddedChatViewController uses resolver + observes splits

**Files:**
- Modify: `Sources/UserInterface/Chat/EmbeddedChatViewController.swift`

This is UI wiring (no unit test); verify by build + manual run.

**Step 1: Switch identifier source to the resolver**

- Line ~91 (`updateAssociatedTab`): `let newIdentifier = state.chatIdentifier(for: tab)`
- Line ~108 (`setupIfNeeded`): `tabIdentifier = state.chatIdentifier(for: tab)`

(`loadAIChatForCurrentTab` already reads `tabIdentifier`; `createAIChatTab`
keeps `chromeTabId = tab.guid`.)

**Step 2: Observe `$splits` and re-resolve**

In `setupIfNeeded()`, after the existing `state.$aiChatTabs` subscription, add:

```swift
        state.$splits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshChatIdentifierIfNeeded()
            }
            .store(in: &cancellables)
```

And add the method (near `loadAIChatForCurrentTab`):

```swift
/// Re-resolves the shared chat identifier when split membership/ownership
/// changes, switching the displayed chat tab if the resolved key moved.
private func refreshChatIdentifierIfNeeded() {
    guard let state = browserState, let tab = associatedTab else { return }
    let resolved = state.chatIdentifier(for: tab)
    guard resolved != tabIdentifier else { return }
    tabIdentifier = resolved
    loadAIChatForCurrentTab()
}
```

**Step 3: Build**

Build the `Phi` scheme via Xcode MCP (or `xcodebuild build -scheme Phi -destination 'platform=macOS'`). Expected: BUILD SUCCEEDED.

**Step 4: Run full unit suite**

Run `xcodebuild test -scheme Phi -destination 'platform=macOS' -only-testing:PhiBrowserTests/SplitChatBindingTests`. Expected: PASS (6 tests).

**Step 5: Commit** (only if user asks)

```bash
git add Sources/UserInterface/Chat/EmbeddedChatViewController.swift
git commit -m "feat: share one chat tab across split panes in embedded chat"
```

---

### Task 5: Manual verification (the 4 principles)

Run the app and verify in each layout (Balanced / Performance / Comfortable):

1. Tab A has a chat tab open → split A with B → chat tab stays A's (principle 1).
2. A and B each have a chat tab → split them with B foreground → chat shows B's,
   A's chat tab is closed (principle 2).
3. In a split with no chat yet, click chat button → exactly one chat tab is
   created, shared by both panes; switching active pane does not switch or
   duplicate it (principle 3).
4. Close one pane → the shared chat tab follows the surviving pane; close the
   survivor → chat tab closes (principle 4).

Also sanity-check: unsplit (drag a pane out) leaves the owner pane with the
chat tab and the other pane chat-less until reopened.

---

## Notes / known limitations (from design)

- `aiChatCollapsed` (expand/collapse) remains per-tab; not shared across panes.
- The chat extension `tabId` context uses the owner pane's guid; not re-pointed
  on active-pane change.
