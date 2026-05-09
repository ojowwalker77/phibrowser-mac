# Sidebar Tab Group Cell Redesign — Implementation Plan

- Date: 2026-05-08
- Branch: `feature/tab-group-sidebar`
- Worktree: `/Users/fydos-mbp-renkai/Desktop/PhiProjects/PhiGithub/phi-browser-mac-worktrees/feature-tab-group-sidebar`
- Design: `docs/plans/2026-05-08-sidebar-tabgroup-cell-redesign-design.md`
- Commit granularity: **B — one commit per phase**

## Pre-flight

- [ ] `git status` clean (after baseline commit of design + plan)
- [ ] Baseline build passes (`xcodebuild -project Phi.xcodeproj -scheme PhiBrowser-canary -configuration Debug build`)
- [ ] All existing `PhiBrowserTests` pass

## Conventions

- Each phase is independently shippable: code compiles, app runs, no
  regressions introduced (visual or behavioral) other than what the phase
  explicitly enables.
- After every phase, run the build target above and the unit test target
  before committing. Manual smoke-test the **regression checklist** items
  marked relevant for the phase.
- Commit messages use a single concise summary line describing what changed
  (per `AGENTS.md` Git Rules).

---

## P0 — Baseline commit (design + plan)

**Goal**: lock in the design + plan in this worktree before any code change.

### Tasks

- [ ] T0.1 Confirm `docs/plans/2026-05-08-sidebar-tabgroup-cell-redesign-design.md` matches the agreed design
- [ ] T0.2 Confirm this plan file is current
- [ ] T0.3 `git add docs/plans/2026-05-08-sidebar-tabgroup-cell-redesign-design.md docs/plans/2026-05-08-sidebar-tabgroup-cell-redesign.md`
- [ ] T0.4 Commit with message: `Add sidebar tab-group cell redesign plan and design docs`

### Acceptance

- `git log -1` shows the new commit
- `git status` is clean
- Build still green

---

## P1 — Data layer foundations

**Goal**: introduce the two new `BrowserState` APIs and flip
`TabGroupSidebarItem.isExpandable` to `false`. The UI should be visually
unchanged at the end of this phase (because the rest of the sidebar code
still reads members through children).

> Design refs: "New `BrowserState` APIs" §, "Outline view contract changes" §.

### Tasks

- [ ] T1.1 `Sources/UserInterface/Sidebar/TabList/TabGroupSidebarItem.swift` — change `isExpandable` to `false`; ensure `TabSectionController` / outline data source still produces zero children for groups (or temporarily route through the existing branch — to be cleaned up in P2 / P3).
- [ ] T1.2 `Sources/States/BrowserState.swift` — add `func moveGroupBlock(token: String, to toIndex: Int)` per design; mirror the local-only flow used by `moveNormalTabLocally`.
- [ ] T1.3 `Sources/States/BrowserState.swift` — add `func convertGroupToBookmarks(token: String, parentFolder: Bookmark?, at index: Int?)` per design.
- [ ] T1.4 `Tests/PhiBrowserTests/BrowserStateTabGroupBlockTests.swift` (new) — unit tests:
  - move group block leaves member relative order intact
  - move group block to before/after another group
  - move group block to start / end of `normalTabs`
  - move group block no-op when `toIndex` is inside the group's existing range
  - convert-group-to-bookmarks preserves member ordering inside target folder
  - convert-group-to-bookmarks dissolves the group entry from `groups`
- [ ] T1.5 Existing `Tests/PhiBrowserTests` pass.
- [ ] T1.6 Build green.

### Acceptance

- All P1 unit tests green
- App runs; tab group rows still expand/collapse via existing chevron (P2 will replace this)
- Whole-group drag is **not** wired yet — that's P5

### Commit

`Add BrowserState moveGroupBlock and convertGroupToBookmarks; mark TabGroupSidebarItem non-expandable`

---

## P2 — View shell swap (TabGroupCellView replaces TabGroupHeaderCellView)

**Goal**: replace the outer outline's group row view. After this phase the
outline shows a single tall cell per group containing the SwiftUI header and
an empty inner table, expanding/collapsing via the SwiftUI chevron.

> Design refs: "Component Details" §, "Architecture Overview / View hierarchy" §, "Risks & Mitigations" rows 1, 2, 7.

### Tasks

- [ ] T2.1 `Sources/UserInterface/Sidebar/TabList/Views/GroupTabsTableView.swift` (new) — `NSTableView` subclass + `GroupTabsTableViewDelegate` per design.
- [ ] T2.2 `Sources/UserInterface/Sidebar/TabList/Views/TabGroupCellView.swift` (new) — replaces `TabGroupHeaderCellView`:
  - subviews: `headerHostingView` (NSHostingView<TabGroupHeaderView>), `innerTable` (GroupTabsTableView)
  - SnapKit constraints per design
  - `configure(with: TabGroupSidebarItem)` plus `prepareForReuse`
  - subscribe to `WebContentGroupInfo.$isCollapsed` → toggle `innerTable.isHidden` and request height update via delegate
  - delegate protocol stub (height-update method only for now; drag methods land in P4 / P5)
  - `static func desiredHeight(for: TabGroupSidebarItem, browserState: BrowserState) -> CGFloat` per the cell-height formula
- [ ] T2.3 `Sources/UserInterface/Sidebar/TabList/Views/TabGroupHeaderView.swift` — add inline chevron icon (`chevron.right`) rotating on `isCollapsed`, with `onTapGesture { viewModel.toggleCollapsed() }`.
- [ ] T2.4 `Sources/UserInterface/Sidebar/TabList/Views/SideBarOutlineView.swift` — remove the group-row chevron override branch from `frameOfOutlineCell` / `frameOfCell`.
- [ ] T2.5 `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`:
  - register reuse identifier for `TabGroupCellView`
  - `outlineView(_:viewFor:item:)` returns a `TabGroupCellView` for `TabGroupSidebarItem`
  - implement `TabGroupCellViewDelegate.tabGroupCellNeedsHeightUpdate(_:for:)` → `outlineView.noteHeightOfRowsWithIndexesChanged([row])` inside an `NSAnimationContext`
  - `outlineView(_:heightOfRowByItem:)` returns `TabGroupCellView.desiredHeight(...)` for groups
  - delete `applyTabGroupCollapseStates` and the group branches inside `shouldExpandItem` / `shouldCollapseItem`
- [ ] T2.6 Keep `TabGroupHeaderCellView.swift` in place — flagged for deletion in P3 once the new cell fully replaces it (per design Open Question §3).
- [ ] T2.7 Build green; manual smoke-test:
  - app launches; existing tab groups appear as a single tall row
  - chevron tap collapses/expands with animated height change
  - group title / color reflect changes from Chromium
  - inner table is empty (members not wired yet — comes in P3)

### Acceptance

- Outer outline shows one cell per group, no native disclosure chevron
- Collapse/expand animates height correctly
- No regressions on ungrouped tab / bookmark / pinned tab rendering
- Build green

### Commit

`Add TabGroupCellView and GroupTabsTableView; replace TabGroupHeaderCellView in sidebar outline`

---

## P3 — Inner table data plumbing (members render)

**Goal**: members render in the inner table with diffable animations. Drag
still flows through the **outer** outline path (carried over from before
this refactor) so that drag works at all times — drag refactor lands in P4.

> Design refs: "Diffable data source" §, "Data Flow & Incremental Updates" §, "Component Details / Combine subscriptions" §.

### Tasks

- [ ] T3.1 `TabGroupCellView` — wire `NSTableViewDiffableDataSource<Section, Int>` (Int = `Tab.guid`) with provider returning a `SidebarTabCellView` (reuse identifier `"InnerGroupTabCell"`).
- [ ] T3.2 `TabGroupCellView.applyMembers(_ newMembers: [Tab], animated: Bool)` per design (snapshot + apply + height update).
- [ ] T3.3 `TabGroupCellView.configure(with:)` initial member load via `browserState.normalTabs.filter { $0.groupToken == token }`.
- [ ] T3.4 `SidebarTabListViewController` — implement `pushMemberUpdatesToGroupCells(_ tokens: Set<String>)` per design.
- [ ] T3.5 `SidebarTabListViewController.applyIncrementalTabChange` — call `pushMemberUpdatesToGroupCells(change.affectedGroupTokens)` after `endUpdates`.
- [ ] T3.6 `TabSectionController` — confirm `affectedGroupTokens` is still populated (no need for `reloadAffectedGroupChildren` anymore — that path becomes a no-op or is removed).
- [ ] T3.7 `SidebarTabListViewController` — remove the grouped-children traversal in `selectActiveTab()` / `applyFocusingSelection()`; group members are no longer outline children.
- [ ] T3.8 Delete `Sources/UserInterface/Sidebar/TabList/Views/TabGroupHeaderCellView.swift` and any references.
- [ ] T3.9 Build green; smoke-test the **visual / state** regression rows from the design checklist:
  - group created → cell appears with header + members
  - member added/removed from any source → animated row insert/remove + cell grows/shrinks
  - group collapsed → cell shrinks; expanded → cell grows; member positions correct
  - member moved across groups → source loses row + target gains row, animated

### Acceptance

- Members render correctly inside the inner table
- Inner table rows animate on member changes
- Outer outline animates root-level group / ungrouped changes correctly in the same frame as inner table animations
- Drag-and-drop still works exactly as before this refactor (no new behavior introduced — outer outline still owns drag)
- All `PhiBrowserTests` pass
- Build green

### Commit

`Render tab group members in inner diffable table; remove TabGroupHeaderCellView`

---

## P4 — Drag source redirect (inner table is now the drag source for grouped tabs)

**Goal**: dragging a grouped tab originates from the inner table, with full
`TabDraggingSession` integration (image-switch + tear-off). The outer
outline stops writing pasteboards for grouped tabs.

> Design refs: "Drag and Drop Architecture / Drag sources" §, "Integration with `TabDraggingSession`" §, "Whole-group drag does NOT participate in image switching / tear-off" §.

### Tasks

- [ ] T4.1 `Sources/UserInterface/Sidebar/TabList/SidebarItem.swift` — add `static let tabGroup = NSPasteboard.PasteboardType("com.phibrowser.tabGroup")` (the type itself is referenced in P4 but only **written** in P5 — keeping the symbol here lets P4 register it on the inner / outer drop sides without edit churn).
- [ ] T4.2 `TabGroupCellView` — `NSTableViewDataSource.pasteboardWriter(forRow:)` writes `.normalTab` (Tab.guid) + `.sourceWindowId` (mirrors the outer outline's existing logic for ungrouped tabs).
- [ ] T4.3 `TabGroupCellView` — `NSTableViewDataSource.tableView(_:draggingSession:willBeginAt:forRowIndexes:)` and `tableView(_:draggingSession:endedAt:operation:)` forward to `TabGroupCellViewDelegate`.
- [ ] T4.4 `GroupTabsTableView.draggingSession(_:movedTo:)` forwards to `phiTableDelegate`; `TabGroupCellView` adopts `GroupTabsTableViewDelegate` and forwards on to `TabGroupCellViewDelegate`.
- [ ] T4.5 `SidebarTabListViewController` — implement the three drag lifecycle methods of `TabGroupCellViewDelegate` per design ("Controller mirrors outer-outline integration" snippet).
- [ ] T4.6 `SidebarTabListViewController.outlineView(_:pasteboardWriterForItem:)` — return `nil` for grouped `Tab` items (they should no longer originate from the outer outline; the inner table is the sole source).
- [ ] T4.7 `TabGroupCellView` — register inner table for drag types: `[.normalTab, .pinnedTab, .phiBookmark, .sourceWindowId]`. (Drop validation lands in P5; the registration is needed earlier so the inner table receives the drag at all.)
- [ ] T4.8 Smoke-test:
  - drag a grouped tab inside the same window, release outside the sidebar = drag image follows cursor (page snapshot via `TabDraggingSession`)
  - drag a grouped tab to empty desktop = tear-off into a new window (existing `TabDraggingSession` path)
  - drag a grouped tab to another window's sidebar (drop targets not yet wired in inner table; outer-outline normal-tab area still works)

### Acceptance

- Grouped tab drag image, image-switch, and tear-off match ungrouped tab behavior
- Outer outline does **not** expose grouped `Tab` outline children or write
  pasteboards for them; grouped-tab gestures still start from the inner table row
- Existing ungrouped drag-and-drop unaffected
- Build green; all `PhiBrowserTests` pass

### Implementation Note — 2026-05-09

The shipped direction was adjusted after debugging grouped tabs that could not
be dragged out of a group:

- `GroupTabsTableView` handles `mouseDown` / `mouseDragged` itself and does not
  call the embedded `NSTableView`'s native drag path for grouped-tab row
  gestures.
- The inner table is still the user-facing gesture source, but the actual
  `NSDraggingSession` is started by `SidebarTabListViewController` through
  `outlineView.beginDraggingSession`.
- This prevents two competing sessions for the same gesture. The failing log
  pattern was: inner table `pasteboardWriter` starts a native session, then the
  controller starts a manual session; the native session later ends with
  `operation=0`, and the outer outline never reaches the intended `acceptDrop`.
- Starting from the outer outline boundary keeps `outlineView(_:validateDrop:)`
  and `outlineView(_:acceptDrop:)` as the drop pipeline for root insertion, so a
  grouped tab dragged outside its group can reuse the existing `.normalTab`
  resolver path and call `removeTabsFromGroup` on accept.
- Because `super.mouseDown` is skipped, click activation is forwarded manually
  from `GroupTabsTableView.didClickRow` to `tab.performAction(with: nil)`.

### Commit

`Route grouped tab drags through inner table with TabDraggingSession integration`

---

## P5 — Drop targets and resolver extensions

**Goal**: inner table accepts drops, whole-group drags work end to end, and
the resolver classifies all the new intents.

> Design refs: "Drag and Drop Architecture / Drop decision matrix" §, "`SidebarGroupDropIntent` extension" §.

### Tasks

- [ ] T5.1 `Sources/UserInterface/Sidebar/TabList/SidebarGroupDropResolver.swift`:
  - extend `SidebarGroupDropIntent` with `moveGroupBlock(token:normalTabsIdx:)` and `convertGroupToBookmarks(token:parentFolder:atIndex:)`
  - extend `RejectReason` with `cannotDropGroupIntoGroup`, `groupCrossWindowUnsupported`
  - extend `SidebarGroupDropContext` with `isInsideInnerGroupTable`, `innerGroupToken`, `innerTableProposedRow`, `innerTableDropOperation`, `wholeGroupSourceToken`, `bookmarkSectionEnd`
  - implement `resolveInnerGroupTable(_:)` and `resolveWholeGroupDrop(_:)` per design tables
  - update `resolveCases` to dispatch into the new helpers
- [ ] T5.2 `Tests/PhiBrowserTests/SidebarGroupDropResolverTests.swift` — add cases for every row of the **Source = `.normalTab`** and **Source = `.tabGroup`** decision matrices, plus `pinnedTab` / `phiBookmark` rejection rows.
- [ ] T5.3 `TabGroupCellView` — implement `NSTableViewDataSource.tableView(_:validateDrop:proposedRow:proposedDropOperation:)` and `tableView(_:acceptDrop:row:dropOperation:)` by:
  - building a `SidebarGroupDropContext` with `isInsideInnerGroupTable = true`, `innerGroupToken`, `innerTableProposedRow`, `innerTableDropOperation`
  - delegating decision to `delegate?.tabGroupCell(self, validateDrop..., atRow:, dropOperation:)`
  - returning `.move` for accepted intents, `[]` for rejected
- [ ] T5.4 `SidebarTabListViewController` — implement `TabGroupCellViewDelegate.tabGroupCell(_:validateDropFromPasteboard:atRow:dropOperation:)` and `tabGroupCell(_:acceptDrop:atRow:)` by reusing a shared `executeDropIntent(_:)` helper that already exists for the outer outline path (extract if not present).
- [ ] T5.5 `SidebarTabListViewController` — outer outline `pasteboardWriterForItem` writes `.tabGroup` (token) + `.sourceWindowId` for `TabGroupSidebarItem` rows.
- [ ] T5.6 `SidebarTabListViewController` — outer outline `validateDrop` / `acceptDrop` dispatch on `.tabGroup` pasteboard:
  - call resolver with `wholeGroupSourceToken`
  - on `.moveGroupBlock(token, idx)` → `browserState.moveGroupBlock(token: token, to: idx)`
  - on `.convertGroupToBookmarks(token, folder, at)` → `browserState.convertGroupToBookmarks(...)`
  - on rejected → `[]`
- [ ] T5.7 Smoke-test the **grouped single-tab paths** and **whole-group paths** sections of the design's Regression checklist.
- [ ] T5.8 Build green; all unit tests pass.

### Acceptance

- Every row of the design's decision matrix produces the expected behavior
- Resolver unit tests cover every new intent and reject reason
- No regressions to the **ungrouped paths** rows of the regression checklist

### Commit

`Add inner-table drop targets, whole-group drag, and resolver intents for moveGroupBlock and convertGroupToBookmarks`

---

## P6 — Whole-group drag image polish + spring-load

**Goal**: drag image for whole-group drag shows only the 36pt header strip,
and spring-loading on a collapsed group (during a drag-over) auto-expands
it.

> Design refs: "Whole-group drag image" §, "Risks & Mitigations" rows 8, 9.

### Tasks

- [ ] T6.1 `SidebarTabListViewController` — in the outer outline drag-image provider for `TabGroupSidebarItem` rows, override `imageComponentsProvider` (or implement `outlineView(_:draggingSession:willBeginAt:forItems:)` to set `enumerateDraggingItems`) to snapshot only `headerHostingView` (36pt header strip). Reuse `SidebarCellView.createDraggingSnapshot` infrastructure if it accepts an arbitrary subview.
- [ ] T6.2 `TabGroupCellView.draggingEntered(_:)` — start a 600ms timer; on fire, if the cell is for a collapsed group and the drag is still inside, send `bridgeAdapter.updateTabGroupCollapsed(token, false)`. (Verify the bridge API name — match what the existing chevron toggle uses.)
- [ ] T6.3 `TabGroupCellView.draggingExited(_:)` — invalidate the spring-load timer; clear any drop-target highlight.
- [ ] T6.4 `TabGroupCellView` — drop-target highlight (cell-level border or background tint) on `draggingEntered` for accepted drag types; clear on exit / drop / cancel.
- [ ] T6.5 Smoke-test:
  - whole-group drag shows a thin (36pt) drag image, not the full multi-row cell
  - dragging onto a collapsed group hovers ~600ms then auto-expands

### Acceptance

- Drag image for whole-group is the header strip
- Spring-load expands collapsed groups during drag-over

### Commit

`Polish whole-group drag image and add spring-load expand on group cell`

---

## P7 — Regression sweep + tests

**Goal**: make sure nothing else regressed and add any missing
verification.

### Tasks

- [ ] T7.1 Walk through the full **Testing / Regression checklist** in the design doc:
  - **ungrouped paths** (6 cases)
  - **grouped single-tab paths** (10 cases)
  - **whole-group paths** (8 cases)
  - **visual / state** (7 cases)
- [ ] T7.2 Run the full test target; fix any failures.
- [ ] T7.3 If any regression checklist case is impractical to verify manually, add a deterministic unit / integration test instead.
- [ ] T7.4 Update `docs/plans/2026-05-08-sidebar-tabgroup-cell-redesign-design.md` "Open Questions for Implementation" with the resolutions found during P1–P6.

### Acceptance

- Full test target green
- Manual regression checklist all pass

### Commit

`Resolve open questions and finalize sidebar tab group cell redesign`

---

## Risk register (pulled from design § "Risks & Mitigations")

| Risk | Phase | Mitigation reminder |
|---|---|---|
| Inner table swallows scroll wheel | P2 | Override `scrollWheel(with:)` to forward up the responder chain |
| Visual flash on collapse/expand | P2 | Wrap `isHidden` toggle + `noteHeightOfRowsWithIndexesChanged` in same `NSAnimationContext` |
| Diffable race vs. outline `endUpdates` | P3 | Apply diffable AFTER `endUpdates` returns |
| Inner cell reuse pool collision | P3 | Identifier `"InnerGroupTabCell"` |
| Whole-group tear-off | P5 | `shouldTrackDraggingImage()` returns false for `TabGroupSidebarItem` (default) |
| Whole-group drag image too large | P6 | `imageComponentsProvider` snapshots header only |
| Drop on collapsed group has no rows | P6 | Spring-load 600ms |

---

## Tracking

Update this section as each phase completes:

- [ ] P0 — Baseline commit
- [ ] P1 — Data layer foundations
- [ ] P2 — View shell swap
- [ ] P3 — Inner table data plumbing
- [ ] P4 — Drag source redirect
- [ ] P5 — Drop targets and resolver extensions
- [ ] P6 — Whole-group drag image polish + spring-load
- [ ] P7 — Regression sweep + tests
