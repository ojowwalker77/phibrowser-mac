# Group Overview Design

Date: 2026-05-28

## Context

Phi Browser already mirrors Chromium tab group state into the native Mac client:

- `BrowserState.groups` owns window-scoped group visual metadata, keyed by group token.
- `Tab.groupToken` is the single source of truth for group membership.
- Sidebar and horizontal tab UIs derive member lists from `BrowserState.normalTabs`.
- `WebContentViewController` owns the left content stack and exposes `hostView` as the web-content-only area below the header and bookmark bar.
- Chromium group commands are routed through the Phi bridge and `TabGroupsProxy`.

Group overview must follow these ownership boundaries. It is a native Mac presentation state, not Chromium internal state and not a synthetic browser tab.

## Goals

Add a group overview page that:

- Shows every tab in a selected group as a card with title, favicon, screenshot, and close button.
- Provides a new-tab button for the group.
- Renders inside `WebContentViewController.hostView`, so it does not cover the address bar or bookmark bar.
- Enters overview from the sidebar tab group header.
- Keeps the horizontal tab layout conservative for now by showing the selected group color state rather than opening the overview from the horizontal strip.
- Makes the address bar empty while overview is active.
- Creates a new tab at index 0 of the current group when the user enters a URL from the address bar while overview is active.
- Keeps the chat button visible when overview is active, subject to the same non-incognito and Phi AI availability rules as normal content.
- Clears overview promptly when the group is removed, closed, or becomes empty.

## Non-Goals

- Do not create a parallel tab-group membership model.
- Do not introduce a global app-scoped state container.
- Do not move per-window state into `AppState`.
- Do not put Chromium-specific group lifecycle logic into UI views.
- Do not redesign horizontal tab group behavior beyond the selected-color placeholder.
- Do not implement group-level AI chat state.

## Recommended Approach

Use a small window-scoped presentation state on `BrowserState`:

```swift
struct GroupOverviewState: Equatable {
    let groupToken: String
}
```

`BrowserState` owns `@Published var groupOverviewState: GroupOverviewState?` plus focused helper methods:

- `showGroupOverview(token:)`
- `clearGroupOverview()`
- `clearGroupOverview(ifToken:)`
- `isShowingGroupOverview(for:)`
- `createTabInCurrentOverviewGroup(url:)`

This keeps the state at the same layer as tabs and groups without changing the source of truth for group membership. The overview only stores the selected token. Member tabs are always derived from:

```swift
browserState.normalTabs.filter { $0.groupToken == token }
```

## Architecture

### BrowserState

`BrowserState` is the owner of window-scoped overview state and lifecycle cleanup.

Responsibilities:

- Store the active overview token.
- Validate that the token still exists in `groups`.
- Clear overview when `handleTabGroupClosed(token:)` removes the group.
- Clear overview when the active group has no remaining members after tab close, tab leave, or membership updates.
- Dispatch the overview address-bar create-tab action through the Chromium integration layer.

`BrowserState` should not cache overview tabs or screenshots.

### WebContentViewController

`WebContentViewController` owns presentation inside `hostView`.

Responsibilities:

- Observe `browserState.groupOverviewState`.
- Show `GroupOverviewViewController` in `hostView` when the state is active.
- Restore the current tab's normal content by calling the existing content update path when overview clears.
- Keep header and bookmark bar layout unchanged.
- Keep the AI chat split view available because overview replaces only host content, not the whole `WebContentViewController`.

The existing `ContentMode` can gain a case for `.groupOverview(token: String)` if useful, but the mode must remain presentation-only. It must not imply that the overview belongs to `associatedTab`.

### GroupOverviewViewController

Add a focused view controller for the overview UI.

Responsibilities:

- Render the group title and tab cards.
- Subscribe to the relevant `BrowserState` publishers.
- Derive member tabs live from `normalTabs`.
- Render each card with title, favicon, screenshot, and close button.
- Expose actions for select tab, close tab, close overview, and new tab.
- Selecting a tab card or creating a new tab from overview exits overview and shows the corresponding tab.

The view controller may use SwiftUI hosted inside AppKit if that matches existing local UI patterns. It must not own Chromium logic.

### Screenshot Source

Screenshots should use the most stable available source:

1. Prefer a snapshot from the tab's native web content view when available.
2. Fall back to a placeholder using the favicon, title, and group color.

Snapshot failures must not block the overview page. Blank or unavailable content should degrade to the placeholder card.

### Sidebar Entry

In sidebar mode, clicking a tab group header enters overview for that group.

The existing group header currently uses the header surface for collapse and drag. Implementation should preserve drag behavior. If collapse still needs a direct click target, the chevron or a small control area should remain the collapse target while the rest of the header enters overview.

The close button remains close-group behavior.

### Horizontal Layout Placeholder

For the horizontal/balanced tab layout, do not open the overview yet. If a horizontal group chip/header click is wired in this scope, it should set only a tab-strip-local selected visual state for that group color block. It should not set `BrowserState.groupOverviewState`, clear the address bar, change tab focus, or change group membership.

## Address Bar Behavior

When overview is active:

- Opening the address bar pre-fills an empty string.
- Address bar submission must not navigate the current focused tab.
- The submitted string is processed through the existing URL processing path.
- Submission calls `BrowserState.createTabInCurrentOverviewGroup(url:)`.
- After dispatching the create request, overview clears and Chromium's active-tab change drives the new tab display.

This requires the address bar model to recognize overview mode as a special navigation target. It should not infer this from `focusingTab` alone.

## Chromium Integration

The current Mac bridge exposes:

```objc
- (void)createTabInGroupWithWindowId:(int64_t)windowId
                            tokenHex:(NSString *)tokenHex;
```

The Chromium implementation currently inserts a foreground New Tab Page at the end of the group's range:

```cpp
gfx::Range range = group->ListTabs();
int insert_index = static_cast<int>(range.end());
chrome::AddTabAt(browser, GURL(), insert_index, true, *group_id);
```

That does not satisfy the overview requirement because overview address-bar submission must create a tab with a specific URL at index 0 of the current group.

Add a new Chromium integration method rather than stitching together create, navigate, and move on the Mac side. Suggested shape:

```objc
- (void)createTabInGroupWithWindowId:(int64_t)windowId
                            tokenHex:(NSString *)tokenHex
                                  url:(NSString *)url
                              atIndex:(NSInteger)groupIndex
                     focusAfterCreate:(BOOL)focusAfterCreate;
```

Chromium should resolve `groupIndex` relative to the group's current contiguous range. For group index 0, insert at `range.start()`. It should call `chrome::AddTabAt` with the processed `GURL`, target index, foreground flag, and group id in one Chromium-side operation.

Failure paths should mirror the existing `CreateTabInGroup` behavior: log and no-op for missing window, unsupported tab strip, invalid token, missing group, invalid URL, or invalid index.

## Lifecycle Rules

Overview clears when:

- The active group closes or is removed.
- The active group has no remaining member tabs.
- The user clicks a tab card and the browser switches to that tab.
- The user clicks the overview new-tab button and Chromium foregrounds the new group tab.
- The user clicks the overview close button.
- The user submits a URL from the address bar and the create-tab request is dispatched.
- The user switches to a normal tab through another browser action.

Overview stays active when:

- A member tab title, favicon, URL, or screenshot changes.
- A member tab is closed but other group members remain.
- A tab leaves the group but other group members remain.
- The group visual data changes.

## AI Chat Behavior

Overview mode shows the chat button when Phi AI is enabled and the window is not incognito.

Do not add group-level chat state. Reuse the current focusing tab as the AI chat association while overview is active. If there is no valid focusing tab, the button should be hidden or disabled until a valid association exists.

## Error Handling

- Missing or stale group token: clear overview.
- Empty member list: clear overview.
- Missing tab snapshot: show placeholder card.
- Missing favicon: show existing default favicon behavior.
- Bridge command failure: leave tab state unchanged and allow Chromium/Mac logs to diagnose.
- Address bar submission without active overview token: fall back to existing address bar behavior.

## Testing Strategy

### Unit and State Tests

Cover `BrowserState` overview lifecycle:

- Showing overview stores only the token.
- Closing the active group clears overview.
- Removing the last member clears overview.
- Removing one member while others remain keeps overview active.
- Switching to a tab clears overview.
- Address-bar submission in overview dispatches group tab creation instead of navigating the focused tab.

### UI Verification

Verify manually or with UI tests where available:

- Sidebar group header enters overview.
- Overview appears only inside `hostView` and does not cover the address bar or bookmark bar.
- Cards show title, favicon, screenshot or placeholder, and close button.
- Closing a card closes that tab and updates the grid.
- Clicking a card focuses the tab and exits overview.
- New-tab button creates a tab in the group, exits overview, and shows the new tab.
- Address bar is empty in overview.
- Address bar URL submission creates a group tab at index 0, exits overview, and shows the new tab.
- Chat button is visible in overview under the expected AI settings.
- Group close removes overview immediately.
- Horizontal layout shows only selected group color state.

### Chromium Verification

Add or update Chromium-side tests for the new bridge method:

- Inserts at group index 0.
- Loads the provided URL.
- Foregrounds the new tab when requested.
- Keeps the tab in the requested group without a transient ungrouped state.
- Rejects invalid tokens and out-of-range indices without mutation.

## Open Decisions Resolved

- Clicking a tab card selects that tab and exits overview.
- Creating a tab from overview exits overview and displays the newly created tab.
- The overview is not represented as a synthetic tab.
- The new index0 URL behavior should be added to the Chromium bridge, not assembled from multiple Mac-side asynchronous operations.
- The design document is written without committing because the repository instructions require explicit user approval before commits.
