# Space window close behavior

Defines what happens when a Space's NSWindow closes, depending on how the close was triggered. Owner: `SpaceWindowSlot.unregisterWindow(for:)` in `SpaceManager.swift`. Every Chromium-side `[NSWindow close]` and AppKit-side `performClose:` funnels into `windowWillClose` → `unregisterWindow`, so this is the single decision point.

## Why two paths exist

A `SpaceWindowSlot` is the user-perceived window. It hosts one `MainBrowserWindowController` per Space ever surfaced from this slot; exactly one is visible at a time. Two close triggers map to different user intent:

- **Tab-driven close** — the user just closed the last tab in the active Space (⌘W on tab, tab-row X button). Chromium auto-closes the Browser, which closes the NSWindow. The user is saying "I'm done with this Space," not "I'm done with this window."
- **Window-driven close** — the user explicitly closed the window itself (red ✕, ⇧⌘W via the Close Window menu item's `performClose:` action, Chromium's internal `BrowserWindowCocoa::Close`). The user is saying "I'm done with this whole window."

By the time `windowWillClose` fires, tab strip state is identical in both cases (Chromium has torn the tabs down already), so the slot needs an out-of-band signal to tell them apart.

## How tab-driven close is tagged

Two entry points dispatch `IDC_CLOSE_TAB` for the active tab:

- `CommandDispatcher.dispatchCommand(.IDC_CLOSE_TAB, …)` — keyboard ⌘W.
- `Tab.close()` — UI X button (`Sources/UserInterface/Common/Tabs/Tab.swift`).

Both check `browserState.tabs.count <= 1` and, if true, call `slot.markTabDrivenClose(for: spaceId)`. The marker is a spaceId → expiration-deadline entry in `pendingTabDrivenCloseDeadlines` on the slot. Any close path that does NOT tag the slot is treated as window-driven by default.

Two robustness rules apply to the tag:

1. **The CommandDispatcher tag is gated on `handleCloseTab()` returning `false`.** `handleCloseTab` swallows ⌘W when the omnibox is open and returns `true` without dispatching anything to Chromium. Tagging in that case would leave a stale marker that the user's next window-driven close would misclassify as tab-driven and route into switch-to-sibling instead of cascade-and-terminate.

2. **Markers have a TTL (`tabDrivenCloseTTL`, currently 2s).** When a dispatched `IDC_CLOSE_TAB` is vetoed — typically an `onbeforeunload` prompt the user cancels — no `unregisterWindow` fires to drain the marker. The TTL caps the stale window so a later window-driven close on the same Space is still correctly classified.

`unregisterWindow` reads `Date() < deadline` to decide `isTabDriven`. Expired markers are drained but not honored.

## Decision matrix

`unregisterWindow(for: spaceId)` decides between three outcomes from `wasVisible` (`visibleController === controller`) and `isTabDriven`:

| `wasVisible` | `isTabDriven` | sibling Space with tabs? | result |
|---|---|---|---|
| true | true | yes | `activate(spaceId: sibling)` — slot stays alive on the sibling. `visibleController` is left pointing at the closing controller so `activate` captures its frame as the inherited frame for the target. |
| true | true | no | cascade — `cascadeCloseRemainingWindows` closes every remaining sibling through Chromium. |
| true | false | (ignored) | cascade. |
| false | false | (ignored) | cascade. |
| false | true | (ignored) | drop only — the controller leaves the map with no side effects. |

The `wasVisible == false && isTabDriven == false` row is why the cascade is **not** gated on `wasVisible` alone: in the slot's native tab group `visibleController` can lag AppKit's actually-selected tab, so a real window-driven close can arrive on a controller that isn't the tracked visible one. Gating the cascade on `wasVisible` only let that close slip through and strand the slot's other Spaces with live tabs. Background closes that must NOT cascade (`deleteSpace` / `changeProfile` / `respawnWindow`) evict the controller first, so they early-return on the identity guard and never reach this branch.

After the body, if `windowsBySpaceId.isEmpty` the slot removes itself from `SpaceManager.slots`. If `SpaceManager.slots` is then empty, the slot calls `NSApp.terminate(nil)` — the user asked for "close all spaces and exit" on window-driven close, and the cleanup path through `applicationShouldTerminate` → `applicationWillTerminate` (see `AppController`) gives Chromium a clean shutdown for SessionService state.

## How the cascade closes windows (`cascadeCloseRemainingWindows`)

The cascade closes each remaining window **through Chromium**, via
`bridge.executeCommand(IDC_CLOSE_WINDOW, windowId:)` →
`chrome::FindBrowserWithID` → `chrome::ExecuteCommand` →
`BrowserWindow::Close`. This is the same path the user's own window close
takes, and it is the fix for the flaky teardown:

- **Why not `NSWindow.close()`.** An earlier version poked each sibling's
  `NSWindow.close()` directly. The slot's windows live in one native tab
  group, and closing several of them — even serialized one per runloop turn —
  raced AppKit's tab-bar selection promotion, dropping some programmatic
  closes and stranding background Spaces with live tabs (with 7 Spaces, ~2
  routinely survived). Driving the close through Chromium tears each `Browser`
  down deterministically and independently of the AppKit tab group.
- **Re-entrancy.** The `isCascadingSlotClose` flag makes each window's later
  `unregisterWindow` (fired when Chromium finishes its teardown) just drop
  from the map instead of re-running a hand-off/cascade; the last drop clears
  the flag and removes the slot.
- **Trade-off: `beforeunload` is honored.** Unlike `NSWindow.close()`,
  `IDC_CLOSE_WINDOW` runs `beforeunload`, so a background Space with unsaved
  changes *and* prior user interaction can surface a dialog — the same
  behavior the visible window already has. (Chrome suppresses the dialog for
  pages with no user gesture, so untouched background Spaces close silently.)

## Sequence (matching log tags)

Window-driven close of a slot with N Spaces:

```
[SpaceWindowSlot] window-driven close of <visibleSpaceId>; cascading N-1 sibling(s) via Chromium
  → cascadeCloseRemainingWindows issues IDC_CLOSE_WINDOW for each remaining sibling;
    each closing sibling drains via the isCascadingSlotClose guard (no further log line),
    and the last drop removes the slot.
```

Tab-driven close with a viable sibling:

```
[SpaceWindowSlot] tab-driven close of <visibleSpaceId>; switching to sibling <siblingSpaceId>
```

(Slot stays alive; no further log line, no terminate.)
