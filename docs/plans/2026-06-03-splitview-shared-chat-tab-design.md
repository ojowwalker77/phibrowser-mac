# Split View Shared Chat Tab — Design

Date: 2026-06-03

## Problem

Normal tabs bind to AI Chat tabs one-to-one via `aiChatTabs[identifier]`, where
`identifier = getTabIdentifier(for:)` (per tab). In a split view two tabs are
shown side by side, but the chat sidebar belongs to whichever pane is the
focusing tab. Switching the active pane switches that pane's
`EmbeddedChatViewController`, which resolves to a different identifier and thus
a different chat tab.

A split view should instead bind to exactly **one** chat tab, shared by both
panes, and switching the active pane must not switch the chat tab.

## Principles

1. If a tab joining the split already has a chat tab, prefer the existing one.
2. If both panes already have a chat tab, prefer the foreground pane's; the
   other chat tab is closed (a split owns exactly one chat tab).
3. Lazy creation (chat button / embedded chat appear) must check whether the
   split already has an associated chat tab and not create a duplicate.
4. When a split pane closes, the shared chat tab follows the surviving pane
   (close order). The chat tab is only closed when the last surviving tab is
   closed.

## Approach

Chosen: **derivation-based shared chat identifier, no extra stored state.**

`aiChatTabs` stays the single source of truth. We do NOT change
`getTabIdentifier` (still used to key per-tab `WebContentViewController`s in
`WebContentContainerViewController`). Instead we add a chat-only resolver that,
for split panes, returns a single shared key derived from `aiChatTabs` itself.
Ownership is never stored separately, so there is no shadow state to keep in
sync (avoids the parallel-state pitfall flagged by AGENTS.md).

Rejected alternatives:
- Stored `splitChatOwnerTabId` map — extra state to sync across split/chat
  lifecycles, prone to drift.
- Keying `aiChatTabs` by `splitId` — a second key scheme parallel to the
  per-tab one; violates pattern stability.

## Design

### 1. Resolver `chatIdentifier(for:)` (BrowserState)

For a tab in a split, scan both panes: whichever pane currently owns the
single shared chat tab in `aiChatTabs` wins; if neither has one yet, return the
foreground pane's id (else primary). Outside a split, fall back to
`getTabIdentifier(for:)`.

All chat code paths (`EmbeddedChatViewController`, `createAIChatTab` callers)
use this resolver. The two webContent-VC keying sites keep using
`getTabIdentifier`.

### 2. Split-creation reconcile (principles 1, 2)

After `handleSplitCreated` builds the `SplitGroup`, call
`reconcileSplitChatBinding(group)`:
- 0 or 1 chat tab among the panes → no-op (resolver handles it; principle 1).
- both panes have a chat tab → keep the foreground pane's, `closeAIChatTab` the
  other (principle 2). The dropped pane's `EmbeddedChatViewController` refreshes
  to the shared chat tab via the split observation in §4.

### 3. Pane close → follow survivor (principle 4)

In `closeTab`, for a normal closing tab that is inside a split AND owns the
shared chat tab (`aiChatTabs[identifier] != nil`), migrate the chat tab to the
surviving pane instead of closing it, via a new
`migrateAIChatTab(fromIdentifier:toIdentifier:)`. Otherwise close as today.
After the split dissolves, the survivor (now standalone) resolves to its own id
and keeps the migrated chat tab. Closing it later closes the chat normally.

### 4. EmbeddedChatViewController

- Replace `getTabIdentifier` with `chatIdentifier(for:)` in `setupIfNeeded`,
  `updateAssociatedTab`, `loadAIChatForCurrentTab`. `createAIChatTab`'s
  `chromeTabId` still uses `associatedTab.guid`.
- Subscribe to `state.$splits` and re-resolve the identifier on change
  (`refreshChatIdentifierIfNeeded`): if the resolved key moved, update
  `tabIdentifier` and reload, switching the displayed chat tab. The existing
  `$aiChatTabs` subscription continues to handle appear/disappear.

Covers: joining a split, the §2 drop-loser case, and split teardown.

## Out of scope

- Sharing the `aiChatCollapsed` (expand/collapse) state across split panes.
  Per-tab collapse may still flip when switching active pane; not part of the
  4 principles. Revisit if needed.
- The chat extension's `tabId` context for the shared chat uses the owner
  pane's guid; it is not re-pointed when the active pane changes.

## Files touched

- `Sources/States/BrowserState.swift` — `chatIdentifier(for:)`,
  `migrateAIChatTab(fromIdentifier:toIdentifier:)`, `closeTab` split branch.
- `Sources/States/BrowserState+Split.swift` — `reconcileSplitChatBinding`,
  call in `handleSplitCreated`.
- `Sources/UserInterface/Chat/EmbeddedChatViewController.swift` — resolver +
  `$splits` observation.
