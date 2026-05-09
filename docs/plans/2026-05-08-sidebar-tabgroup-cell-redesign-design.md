# Sidebar Tab Group Cell Redesign — Design Document

- Date: 2026-05-08
- Branch: `feature-tab-group`
- Status: Approved (brainstorming complete)

## Goal

Refactor how a Chromium tab group is presented in the sidebar's `NSOutlineView`.
Currently each grouped tab is a child outline row of a `TabGroupSidebarItem`,
with the group expand/collapse driven by the outline's native disclosure
chevron. This refactor turns each tab group into **one self-contained outline
cell** that internally hosts a SwiftUI group header plus a member tab list
rendered by an embedded `NSTableView` (without a `NSScrollView`).

The change is **UI-only** for the sidebar layer. `BrowserState` keeps its flat
`normalTabs` array as the single source of truth — group structure is built up
in the sidebar layer for rendering only.

## Non-Goals

- Do **not** change `BrowserState.normalTabs` flatness or `Tab.groupToken` as
  the membership source of truth.
- Do **not** rework bookmark / pinned tab rendering.
- Do **not** change Chromium-side tab group commands.
- Do **not** touch the horizontal-bar tab strip (`Sources/UserInterface/HorizontalBar`).

## Approved Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Inner container = `NSTableView` **without** an enclosing `NSScrollView` | Eliminates inner/outer scroll competition and scrollbars; outer outline scrolls the whole cell |
| 2 | Drag handoff = **Hybrid** — inner table owns hit-testing / gesture detection; grouped-tab drag sessions are started from the outer outline boundary; decisions still flow through `SidebarGroupDropResolver` | Keeps a single decision source and avoids AppKit conflicts between embedded-table drag sessions and outer-outline drop handling |
| 3 | Whole-group drag → bookmark area is allowed (converts members to bookmarks + dissolves group). The reverse (bookmark folder → tab group) is **not** allowed | User-confirmed product behavior |
| 4 | Drag-source target for whole-group drag = group header strip (color bar + title) only | macOS-natural; member rows are always single-tab drags |
| 5 | Spring-loading on a collapsed group during drag = **kept** | Matches existing UX |
| 6 | `focusingTab` inside a collapsed group = **no special visual** | Owned by Chromium-side logic, out of scope |
| 7 | Group cell instance lifetime = standard `makeView(withIdentifier:)` reuse with `prepareForReuse` cleanup | AppKit-standard pattern |
| 8 | Active-tab highlight inside the inner table = driven by SwiftUI `model.isActive` only; inner table does not participate in selection | Less code, no cross-table selection coordination |
| 9 | Inner table data source = `NSTableViewDiffableDataSource` (modern, automatic diff) | User-requested; eliminates hand-written diff code |

## Architecture Overview

### View hierarchy

```
SidebarTabListViewController
└── SideBarOutlineView (outer NSOutlineView; unchanged)
    ├── BookmarkCellView          (unchanged)
    ├── SidebarTabCellView        (ungrouped normal tab; unchanged)
    ├── NewTabButtonCellView      (unchanged)
    ├── SeparatorCellView         (unchanged)
    └── TabGroupCellView          (NEW; replaces TabGroupHeaderCellView)
        ├── headerHostingView     (NSHostingView<TabGroupHeaderView>) — 36pt
        └── innerTableView        (GroupTabsTableView : NSTableView)  — dynamic
            └── SidebarTabCellView (reused, with a different reuse identifier)
```

### Outline view contract changes

- `TabGroupSidebarItem.isExpandable` flips from `true` to `false`. Outer outline
  treats the group row as a leaf with a tall, dynamic height.
- `numberOfChildrenOfItem` returns 0 for `TabGroupSidebarItem`.
- Native chevron / expand/collapse routing for tab groups is removed:
  `applyTabGroupCollapseStates`, `shouldExpandItem`/`shouldCollapseItem` group
  branches, and `SideBarOutlineView.frameOfOutlineCell` group-row override are
  deleted. The chevron is drawn inside the SwiftUI header.

### Source-of-truth model

- `BrowserState.normalTabs: [Tab]` — flat, ordered.
- `BrowserState.groups: [String: WebContentGroupInfo]` — mirrors Chromium tab
  groups, keyed by hex token.
- `Tab.groupToken: String?` — single source of truth for membership.
- `TabSectionController` continues to fold these into `tabItems: [SidebarItem]`,
  emitting one `TabGroupSidebarItem` per group at the position of its first
  member, plus standalone `Tab` entries for ungrouped tabs.

## Component Details

### `TabGroupCellView`

```
TabGroupCellView : SidebarCellView
- Inputs:
    weak var delegate: TabGroupCellViewDelegate?
    item -> TabGroupSidebarItem (set via configure(with:))
- Owned subviews:
    headerHostingView: NSHostingView<TabGroupHeaderView>
    innerTable:        GroupTabsTableView (no NSScrollView)
- Internal state:
    token:              String
    tabsByGuid:         [Int: Tab]
    currentMemberOrder: [Int]
    cancellables:       Set<AnyCancellable>
    springLoadTimer:    Timer?
    isDropTargetHighlighted: Bool
    diffableDataSource: NSTableViewDiffableDataSource<Section, Int>
```

Layout:
- header: top/leading/trailing 0, height 36
- innerTable: top = header.bottom + 4pt, leading/trailing 0, bottom = cell.bottom - 4pt
- innerTable config: `rowHeight = 36`, `selectionHighlightStyle = .none`,
  `headerView = nil`, `gridStyleMask = .gridNone`, `backgroundColor = .clear`

Cell-height formula:
```
cellHeight = 36 (header)
           + (group.isCollapsed ? 0 : memberCount * 36 + 4 + 4)
```

### Diffable data source

```swift
private enum Section { case members }

private lazy var diffableDataSource: NSTableViewDiffableDataSource<Section, Int> = {
    NSTableViewDiffableDataSource(tableView: innerTable) { [weak self] tv, col, row, tabGuid in
        guard let self, let tab = self.tabsByGuid[tabGuid] else { return NSView() }
        let identifier = NSUserInterfaceItemIdentifier("InnerGroupTabCell")
        let cell = tv.makeView(withIdentifier: identifier, owner: self) as? SidebarTabCellView
            ?? SidebarTabCellView()
        cell.identifier = identifier
        cell.delegate = self.tabCellDelegate
        cell.configure(with: tab)
        return cell
    }
}()

func applyMembers(_ newMembers: [Tab], animated: Bool) {
    tabsByGuid = Dictionary(uniqueKeysWithValues: newMembers.map { ($0.guid, $0) })
    currentMemberOrder = newMembers.map(\.guid)

    var snap = NSDiffableDataSourceSnapshot<Section, Int>()
    snap.appendSections([.members])
    snap.appendItems(currentMemberOrder, toSection: .members)
    diffableDataSource.apply(snap, animatingDifferences: animated)

    delegate?.tabGroupCellNeedsHeightUpdate(self, for: token)
}
```

Cell uses identifier `"InnerGroupTabCell"` to keep the inner table reuse pool
separate from the outer outline's `"TabCell"` pool.

### Cell-controller delegate

```swift
protocol TabGroupCellViewDelegate: AnyObject {
    // Height
    func tabGroupCellNeedsHeightUpdate(_ cell: TabGroupCellView, for token: String)

    // Drag source life-cycle (forwarded to TabDraggingSession via the controller)
    func tabGroupCell(_ cell: TabGroupCellView,
                      willBeginDragging session: NSDraggingSession,
                      draggingItem: Any?,
                      screenLocation: CGPoint)
    func tabGroupCell(_ cell: TabGroupCellView,
                      draggingSession session: NSDraggingSession,
                      movedTo screenPoint: CGPoint)
    func tabGroupCell(_ cell: TabGroupCellView,
                      endedDragging session: NSDraggingSession,
                      screenLocation: CGPoint,
                      operation: NSDragOperation)

    // Drop intent
    func tabGroupCell(_ cell: TabGroupCellView,
                      validateDropFromPasteboard: NSPasteboard,
                      atRow: Int,
                      dropOperation: NSTableView.DropOperation) -> SidebarGroupDropIntent
    func tabGroupCell(_ cell: TabGroupCellView,
                      acceptDrop info: NSDraggingInfo,
                      atRow: Int) -> Bool

    // Tab close (forwarded from inner SidebarTabCellView)
    func tabGroupCellTabCellDidRequestClose(_ cell: TabGroupCellView, tab: Tab)
}
```

### Combine subscriptions inside `TabGroupCellView`

The cell only subscribes to inputs that the controller cannot push precisely:

- `WebContentGroupInfo.$isCollapsed` → toggle `innerTable.isHidden` and trigger
  height update
- (the SwiftUI `TabGroupHeaderViewModel` already subscribes to `$title` /
  `$color`; the cell does not duplicate)

The cell **does not** subscribe to `BrowserState.$normalTabs`. Member updates
are pushed in by the controller (see Data Flow).

### `GroupTabsTableView` subclass

```swift
final class GroupTabsTableView: NSTableView {
    weak var phiTableDelegate: GroupTabsTableViewDelegate?
    private var pendingDragRow: Int?
    private var pendingMouseDownEvent: NSEvent?
    private var manualDragInProgress = false

    override func mouseDown(with event: NSEvent) {
        pendingDragRow = row(at: convert(event.locationInWindow, from: nil))
        pendingMouseDownEvent = event
        manualDragInProgress = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !manualDragInProgress,
              let row = pendingDragRow,
              row >= 0,
              let mouseDownEvent = pendingMouseDownEvent else { return }
        manualDragInProgress = true
        phiTableDelegate?.tableView(self,
                                    beginDraggingRow: row,
                                    with: mouseDownEvent)
    }

    override func mouseUp(with event: NSEvent) {
        if !manualDragInProgress,
           let row = pendingDragRow,
           row >= 0 {
            phiTableDelegate?.tableView(self, didClickRow: row)
        }
        pendingDragRow = nil
        pendingMouseDownEvent = nil
        manualDragInProgress = false
    }
}

protocol GroupTabsTableViewDelegate: AnyObject {
    func tableView(_ tv: GroupTabsTableView,
                   beginDraggingRow row: Int,
                   with event: NSEvent)
    func tableView(_ tv: GroupTabsTableView,
                   didClickRow row: Int)
}
```

Important implementation note:

- `GroupTabsTableView` intentionally does **not** call `super.mouseDown` /
  `super.mouseDragged` for grouped-tab row gestures. Letting the embedded
  `NSTableView` start its native row drag creates a separate `NSDraggingSession`
  that does not reliably enter the outer outline's destination pipeline.
- On drag, the table forwards the original mouse-down event and row to
  `TabGroupCellView`, which maps the row to a `Tab` and row cell snapshot.
  `SidebarTabListViewController` then calls `outlineView.beginDraggingSession`
  with `.normalTab` + `.sourceWindowId`.
- On click (no drag), the table forwards `didClickRow`, and the cell calls
  `tab.performAction(with: nil)` so activation still matches ungrouped tabs.

## Drag and Drop Architecture

### Pasteboard types

| Type | Payload | Notes |
|---|---|---|
| `.normalTab` (existing) | `Tab.guid` (Int) | Used by both outer outline (ungrouped tab) and inner table (grouped tab). The same type means the outer's existing validate/accept logic transparently handles drops from inner tables. |
| `.tabGroup` (NEW) | group token (hex String) | Whole-group drag |
| `.pinnedTab` (existing) | `Tab.guidInLocalDB` | Unchanged |
| `.phiBookmark` (existing) | `Bookmark.guid` | Unchanged |
| `.sourceWindowId` (existing) | window id String | Continues to be set on every pasteboard for cross-window detection |

### Drag sources

| Source view | Item type | Pasteboard types written |
|---|---|---|
| outer outline | `Tab` (ungrouped) | `.normalTab`, `.sourceWindowId` |
| outer outline | `TabGroupSidebarItem` | `.tabGroup`, `.sourceWindowId` |
| outer outline | `Bookmark` | `.phiBookmark`, `.sourceWindowId` |
| outer outline | pinned `Bookmark` | `.pinnedTab`, `.sourceWindowId` |
| **inner table gesture -> outer outline session** | `Tab` (grouped) | `.normalTab`, `.sourceWindowId` |

The outer outline's `pasteboardWriterForItem` no longer writes anything for
grouped `Tab`s (the inner table is now the source).

For grouped single-tab drags, "inner table is the source" means the user
gesture begins on the embedded table row. The actual AppKit drag session is
created by `SidebarTabListViewController` via `outlineView.beginDraggingSession`.
This is deliberate: it keeps `NSOutlineView.validateDrop` / `acceptDrop` as the
drop boundary for pulling a tab out of a group, while avoiding a competing
embedded-table native drag session.

### Drop targets

Outer outline accepts `.normalTab` / `.tabGroup` / `.pinnedTab` /
`.phiBookmark`. Inner table accepts only `.normalTab` (grouped or ungrouped
single tab). All decisions go through `SidebarGroupDropResolver.resolve(_)`.

### `SidebarGroupDropIntent` extension

```swift
enum SidebarGroupDropIntent: Equatable {
    case rootInsert(normalTabsIdx: Int)
    case joinAtFront(token: String, normalTabsIdx: Int)
    case reorderInGroup(token: String, normalTabsIdx: Int)

    // NEW
    case moveGroupBlock(token: String, normalTabsIdx: Int)
    case convertGroupToBookmarks(token: String, parentFolder: Bookmark?, atIndex: Int?)

    case rejected(reason: RejectReason)

    enum RejectReason: Equatable {
        case crossWindowRefused
        case crossWindowGroupJoinUnsupported
        case pinnedNotAllowedInGroup
        case bookmarkNotAllowedInGroup
        case sameSlot
        // NEW
        case cannotDropGroupIntoGroup
        case groupCrossWindowUnsupported
    }
}
```

### Drop decision matrix

#### Source = `.normalTab`

| Target | Intent |
|---|---|
| outer outline ungrouped row gap | `.rootInsert(idx)` |
| outer outline bookmark folder | (existing path) `bookmarkSectionController.handleDrop` |
| outer outline bookmark root area | (existing path) reverse handler |
| group header upper half | `.rootInsert(beforeGroupIdx)` |
| group header lower half | `.joinAtFront(token, lowerBound)` (or spring-load expand) |
| inner table row upper half | `.reorderInGroup(token, lowerBound + memberIdx)` |
| inner table row lower half | `.reorderInGroup(token, lowerBound + memberIdx + 1)` |

#### Source = `.tabGroup`

| Target | Intent |
|---|---|
| outer outline ungrouped row gap | `.moveGroupBlock(token, idx)` |
| another group header upper half | `.moveGroupBlock(token, otherLowerBound)` |
| another group header lower half | `.moveGroupBlock(token, otherUpperBound + 1)` |
| inner table (any group) | `.rejected(.cannotDropGroupIntoGroup)` |
| outer outline bookmark folder | `.convertGroupToBookmarks(token, folder, idx)` |
| outer outline bookmark root area | `.convertGroupToBookmarks(token, nil, idx)` |
| cross-window | `.rejected(.groupCrossWindowUnsupported)` |
| same slot | `.rejected(.sameSlot)` |

#### Source = `.pinnedTab` / `.phiBookmark`

| Target | Intent |
|---|---|
| outer outline ungrouped / bookmark | (existing paths) |
| inner table | `.rejected(.pinnedNotAllowedInGroup / .bookmarkNotAllowedInGroup)` |
| outer outline group header | (existing handling — already rejected by current resolver) |

### Inner-table drop visuals

NSTableView's native blue insertion line is used for indicator. The cell
returns `NSDragOperation.move` from `validateDrop` when the resolver classifies
the drop as a valid `reorderInGroup` / `joinAtFront`, otherwise `[]`.

### Whole-group drag image

In `pasteboardWriterForItem` for `TabGroupSidebarItem`, the controller (or the
outline view delegate) overrides `draggingImageComponents` to render only the
36pt header strip, not the entire cell. Reuses
`SidebarCellView.createDraggingSnapshot` infrastructure, but on
`headerHostingView` instead of `backgoundView`.

## Integration with `TabDraggingSession`

The session enables (a) drag-image switching to a page snapshot when the cursor
leaves the source window and (b) automatic tear-off to a new browser window
when the drop happens on empty desktop.

### Inner table forwards three lifecycle points to the controller

```swift
extension TabGroupCellView: NSTableViewDataSource {
    // pasteboardWriterForRow — write .normalTab + .sourceWindowId

    func tableView(_ tv: NSTableView,
                   draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        guard let row = rowIndexes.first, let tab = tabAt(row: row) else { return }
        delegate?.tabGroupCell(self,
                               willBeginDragging: session,
                               draggingItem: tab,
                               screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y))
    }

    func tableView(_ tv: NSTableView,
                   draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        delegate?.tabGroupCell(self,
                               endedDragging: session,
                               screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
                               operation: operation)
    }
}

extension TabGroupCellView: GroupTabsTableViewDelegate {
    func tableView(_ tv: GroupTabsTableView,
                   draggingSession session: NSDraggingSession,
                   movedTo screenPoint: NSPoint) {
        delegate?.tabGroupCell(self,
                               draggingSession: session,
                               movedTo: CGPoint(x: screenPoint.x, y: screenPoint.y))
    }
}
```

### Controller mirrors outer-outline integration

```swift
extension SidebarTabListViewController: TabGroupCellViewDelegate {
    func tabGroupCell(_ cell, willBeginDragging session, draggingItem, screenLocation) {
        DispatchQueue.main.async {
            self.expandFloatingBookmarkParentsIfNeeded()
            self.browserState.isDraggingTab = true
        }
        browserState.tabDraggingSession.attachNativeSession(session)
        browserState.tabDraggingSession.begin(
            draggingItem: draggingItem,
            screenLocation: screenLocation,
            containerView: hostVC?.view)
    }

    func tabGroupCell(_ cell, draggingSession, movedTo screenPoint) {
        browserState.tabDraggingSession.attachNativeSession(draggingSession)
        browserState.tabDraggingSession.update(screenLocation: screenPoint)
    }

    func tabGroupCell(_ cell, endedDragging session, screenLocation, operation) {
        clearDropFeedback()
        DispatchQueue.main.async { self.browserState.isDraggingTab = false }
        browserState.tabDraggingSession.end(screenLocation: screenLocation,
                                            dragOperation: operation)
    }
}
```

### Whole-group drag does NOT participate in image switching / tear-off

`TabGroupSidebarItem` is not a `Tab` and not a `Bookmark`, so
`SidebarItem.shouldTrackDraggingImage()` returns false (existing default
behavior). `TabDraggingSession.shouldSwitchDragImage(for:)` therefore returns
false for whole-group drags, and the page-snapshot / tear-off code paths are
naturally skipped — matching Chromium behavior (you cannot tear-off a whole
group into a new window).

## Data Flow & Incremental Updates

### Three update paths

| Trigger | Routing |
|---|---|
| `BrowserState.$groups` (group created/closed) | outer outline root insert/remove (driven by `TabSectionController` diff) |
| ungrouped `Tab` insert/remove/move | outer outline root insert/remove/move (existing) |
| group's root-level position changed | outer outline `moveItem` (existing) |
| **group member added/removed/reordered (group still exists)** | controller pushes new members to the affected `TabGroupCellView` via `applyMembers(_:animated:)` |
| group title / color | SwiftUI `TabGroupHeaderViewModel` self-subscription (existing) |
| group `isCollapsed` | cell self-subscription → toggle `innerTable.isHidden` + height update |

### Member-update push path

```swift
private func applyIncrementalTabChange(_ change: TabSectionChange) {
    // ... existing item building / tabSectionStart calc ...

    let hasStructuralChanges = change.moveOperation != nil
        || !change.removedIndices.isEmpty
        || !change.insertedIndices.isEmpty

    if hasStructuralChanges {
        outlineView.beginUpdates()
        // existing root-level insert/remove/move
        outlineView.endUpdates()
    }

    pushMemberUpdatesToGroupCells(change.affectedGroupTokens)
    // existing selection / scrolling tail
}

private func pushMemberUpdatesToGroupCells(_ tokens: Set<String>) {
    guard !tokens.isEmpty else { return }
    for case let groupItem as TabGroupSidebarItem in allItems
        where tokens.contains(groupItem.group.token) {
        let row = outlineView.row(forItem: groupItem)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row,
                                          makeIfNecessary: false) as? TabGroupCellView
        else { continue }
        let newMembers = browserState.normalTabs.filter {
            $0.groupToken == groupItem.group.token
        }
        cell.applyMembers(newMembers, animated: true)
    }
}
```

### Same-frame animation guarantee

```
[same Run Loop tick]
  outlineView.beginUpdates()
  outline-level insert/remove/move
  outlineView.endUpdates()                       ← outer animation starts
  for each affected group cell:
    applyMembers → diffable.apply(animated: true) ← inner table animation starts
    delegate.tabGroupCellNeedsHeightUpdate
      → outline.noteHeightOfRowsWithIndexesChanged(_)  ← cell height animation
```

AppKit merges all of these into the same animation transaction. Cells that
are not yet realized (just-inserted root row, or off-screen) are skipped — they
will pull initial members from `groupItem.group` + `normalTabs.filter` on first
`configure(with:)`.

## New `BrowserState` APIs

```swift
extension BrowserState {
    /// Reorder all members of `token` as a contiguous block to land at
    /// `toIndex` in `normalTabs`. Members are spliced as a unit, preserving
    /// their relative order. Local-only (no bridge call) — Chromium will
    /// echo the reorder back via `OnTabStripModelChanged`, mirroring
    /// `moveNormalTabLocally`.
    func moveGroupBlock(token: String, to toIndex: Int)

    /// Dissolve `token` and convert all members to bookmarks, optionally
    /// inside `parentFolder` (nil = bookmark root) at `index`. Internally:
    ///   1. removeTabsFromGroup(memberIds)         (bridge)
    ///   2. for each member, bookmarkSection.handleDrop(of: tab, to: parentFolder, at: idx)
    ///   3. closeGroup(token)                      (bridge — defensive)
    /// Whether members' tabs are also closed depends on the existing
    /// "single tab → bookmark folder" semantics; verify and align in
    /// implementation.
    func convertGroupToBookmarks(token: String,
                                 parentFolder: Bookmark?,
                                 at index: Int?)
}
```

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Inner table without `NSScrollView` swallows scroll wheel | Verify; if needed, override `scrollWheel(with:)` to forward to outer outline's scroll view via the responder chain |
| Visual flash when expanding/collapsing | Wrap `isHidden` toggle and `noteHeightOfRowsWithIndexesChanged` in the same `NSAnimationContext` |
| Diffable apply races with `endUpdates` | Always apply diffable AFTER `endUpdates` returns; cells that no longer exist in the outline cannot be addressed by `view(atColumn:row:makeIfNecessary:false)` — naturally skipped |
| Whole-group drag triggers tear-off | `shouldTrackDraggingImage()` returns false for `TabGroupSidebarItem` (default) — guards `TabDraggingSession`'s image-switch + tear-off path |
| Inner cell reuse pool collides with outer's | Use distinct identifier `"InnerGroupTabCell"` |
| `focusingTab` inside collapsed group not visible | Out of scope — Chromium owns this UX |
| Whole-group drag image too large | Override `draggingImageComponents` for `TabGroupSidebarItem` rows to snapshot only the 36pt header |
| Drop target on collapsed group has no member rows | Spring-load: 600ms timer on `draggingEntered`, then bridge `updateTabGroupCollapsed(false)` to expand |

## Testing

### Regression checklist (must keep working)

**ungrouped paths**:
- normal tab reorder
- normal tab → bookmark folder = convert
- normal tab → bookmark root = convert
- bookmark → normal-tab area = convert
- pinned tab → normal-tab area = unpin
- pinned tab → bookmark folder = convert

**grouped single-tab paths**:
- intra-group reorder
- grouped tab → ungrouped area = ungroup
- grouped tab → bookmark folder = convert + ungroup
- grouped tab → bookmark root = convert + ungroup
- ungrouped tab → group inner table = join
- ungrouped tab → group header lower half = joinAtFront
- ungrouped tab → collapsed group = spring-load expand + join
- cross-window into target window's inner table = rejected, falls back to ungrouped area
- cross-window out (drag inner-table tab to another window) = ungroup at source, ungrouped at target
- cross-window to empty desktop = tear-off into new window

**whole-group paths (NEW)**:
- whole group → normal-tab area = block reorder
- whole group → another group header upper half = land before that group
- whole group → another group header lower half = land after that group
- whole group → inner table = rejected
- whole group → bookmark folder = convert all + dissolve
- whole group → bookmark root = convert all + dissolve
- whole group → cross-window = rejected
- whole group → same slot = rejected (sameSlot)

**visual / state**:
- group created → cell appears with header + inner table
- group closed → cell removed (animated)
- group collapsed → cell shrinks to 36pt; member active state preserved (Chromium-side)
- group expanded → cell grows; member positions correct
- member added (any source) → inner table inserts row (animated) + cell grows
- member removed → inner table removes row (animated) + cell shrinks
- member moved across groups → source loses row + target gains row (animated)

### Unit tests to add

- Resolver tests for the two new intents (`moveGroupBlock`, `convertGroupToBookmarks`)
  and the two new reject reasons
- `BrowserState.moveGroupBlock` index math — splice preserves member order in
  contiguous and (transient) non-contiguous frames
- `BrowserState.convertGroupToBookmarks` member close vs. survival behavior

## Implementation Sequence (each phase independently shippable)

```
P1. Data layer foundations
    - TabGroupSidebarItem.isExpandable → false
    - BrowserState.moveGroupBlock(token:to:) + unit tests
    - BrowserState.convertGroupToBookmarks(...) + unit tests
    (Visually unchanged after this phase.)

P2. View shell swap
    - GroupTabsTableView (empty NSTableView subclass)
    - TabGroupCellView (replaces TabGroupHeaderCellView)
    - outline view's `viewFor` returns TabGroupCellView
    - delete applyTabGroupCollapseStates, shouldExpand/CollapseItem group branches
    - delete SideBarOutlineView's group chevron override
    - chevron moved into SwiftUI TabGroupHeaderView
    - cell subscribes to isCollapsed, drives height
    (Collapse/expand should now work.)

P3. Inner table data plumbing
    - Diffable data source wired
    - controller's pushMemberUpdatesToGroupCells implemented
    - reloadAffectedGroupChildren rewritten
    - selectActiveTab's grouped-children traversal removed
    (Group members render and animate; drag still on the old path.)

P4. Drag source redirect
    - Inner-table pasteboardWriterForRow + willBeginAt + endedAt
    - GroupTabsTableView.draggingSession(_:movedTo:) forwards
    - TabGroupCellViewDelegate forwards to controller
    - controller wires TabDraggingSession (mirrors outer outline)
    - outer outline pasteboardWriterForItem stops writing for grouped Tab

P5. Drop target & resolver extensions
    - Inner-table validateDrop / acceptDrop (call into controller's resolver)
    - SidebarGroupDropResolver: moveGroupBlock + convertGroupToBookmarks
    - outer outline acceptDrop dispatches .tabGroup pasteboard
    - outer outline pasteboardWriterForItem writes .tabGroup for TabGroupSidebarItem

P6. Whole-group drag image polish
    - pasteboardWriterForItem (group) overrides imageComponentsProvider
      to snapshot the 36pt header only
    - Validate spring-load + drop-feedback highlight on the cell

P7. Regression + tests
    - All existing PhiBrowserTests pass
    - New resolver + BrowserState API unit tests
    - Manual run through the regression checklist
```

Each phase compiles and is independently testable.

## Open Questions for Implementation

1. `BrowserState.convertGroupToBookmarks` — confirm whether the existing
   "single tab → bookmark folder" path closes the source tab. The whole-group
   path must mirror that decision.
2. Spring-load timeout — current code (in `shouldExpandItem` for
   `TabGroupSidebarItem`) doesn't have an explicit timer; verify what AppKit
   default is doing today, then port the same delay (typical Apple default
   is ~600ms) into `TabGroupCellView.draggingEntered`.
3. Outer outline's `viewFor` swap from `TabGroupHeaderCellView` to
   `TabGroupCellView` — keep both classes during P2 to make rollback easy,
   delete `TabGroupHeaderCellView` after P3 lands.

## Related Files

Existing (will be modified):
- `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`
- `Sources/UserInterface/Sidebar/TabList/TabSectionController.swift`
- `Sources/UserInterface/Sidebar/TabList/TabGroupSidebarItem.swift`
- `Sources/UserInterface/Sidebar/TabList/SidebarGroupDropResolver.swift`
- `Sources/UserInterface/Sidebar/TabList/Views/SideBarOutlineView.swift`
- `Sources/UserInterface/Sidebar/TabList/Views/TabGroupHeaderCellView.swift` (replaced)
- `Sources/UserInterface/Sidebar/TabList/Views/TabGroupHeaderView.swift`
- `Sources/States/BrowserState.swift`
- `Tests/PhiBrowserTests/SidebarGroupDropResolverTests.swift`

New:
- `Sources/UserInterface/Sidebar/TabList/Views/TabGroupCellView.swift`
- `Sources/UserInterface/Sidebar/TabList/Views/GroupTabsTableView.swift`
