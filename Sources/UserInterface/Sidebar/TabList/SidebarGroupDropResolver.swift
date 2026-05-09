// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

/// Test seam: anything that exposes a tab-group token via the
/// `wrappedGroupToken` property can stand in for a sidebar group
/// header in the resolver. The production conformer is
/// `TabGroupSidebarItem`; tests provide a lightweight stub so we
/// don't need to build a full `BrowserState` to exercise the resolver.
protocol SidebarGroupHeaderItem: AnyObject {
    var wrappedGroupToken: String { get }
}

extension TabGroupSidebarItem: SidebarGroupHeaderItem {
    var wrappedGroupToken: String { group.token }
}

/// Final classification of a sidebar drag-drop's intent. The resolver
/// produces this from AppKit's raw report; the controller acts on it.
enum SidebarGroupDropIntent: Equatable {
    /// Drop outside any group, at the given index in `BrowserState.normalTabs`.
    case rootInsert(normalTabsIdx: Int)

    /// Join the group as its FIRST member; `normalTabsIdx` is the
    /// insertion point (= the group's current `lowerBound` in `normalTabs`).
    case joinAtFront(token: String, normalTabsIdx: Int)

    /// Stay inside (or join) the group at `normalTabsIdx`. The semantic
    /// position is "insert before the tab currently at this idx".
    /// `idx == lowerBound` is equivalent to `joinAtFront`; resolver
    /// prefers the more specific case in that situation.
    case reorderInGroup(token: String, normalTabsIdx: Int)

    /// Drop is rejected (with reason for logging).
    case rejected(reason: RejectReason)

    enum RejectReason: Equatable {
        case crossWindowRefused
        case crossWindowGroupJoinUnsupported
        case pinnedNotAllowedInGroup
        case bookmarkNotAllowedInGroup
        case sameSlot
    }
}

/// Pasteboard kind that triggered the drag.
enum PasteboardKind: Equatable {
    case normalTab
    case pinnedTab
    case phiBookmark
    case unknown
}

/// Inputs the resolver needs to classify a single drop. The controller
/// pre-queries geometry and helper closures so the resolver itself
/// stays free of AppKit/`NSOutlineView` references and can be unit
/// tested with simple mocks.
struct SidebarGroupDropContext {
    let proposedItem: Any?
    let proposedChildIndex: Int
    let cursorYInOutline: CGFloat
    let outlineIsFlipped: Bool
    /// Frame (in outline coords) of whichever row corresponds to
    /// `proposedItem`. `nil` when there is no such row (root drop).
    let rowFrameForProposedItem: CGRect?
    let pasteboardKind: PasteboardKind
    let isCrossWindow: Bool
    let crossWindowAccepted: Bool
    let draggingTab: Tab?
    /// 0-based idx of the proposed Tab inside its group (only when
    /// `proposedItem` is a Tab with `groupToken != nil`).
    let memberIdxInGroupForProposedTab: Int?
    /// `[lowerBound..<lowerBoundExclusive)` for a token's contiguous
    /// run in `normalTabs`; `nil` if no such group.
    let groupRangeInNormalTabs: (String) -> Range<Int>?
    /// Translate AppKit's outline-root index into a `normalTabs`
    /// insertion index. Encapsulates the existing
    /// `calculateTabDestinationIndex(from:)` logic.
    let resolveNormalTabsIdx: (_ outlineRootIdx: Int) -> Int
    /// `normalTabs` index of the proposed Tab when `proposedItem`
    /// is a Tab. `nil` otherwise.
    let normalTabsIdxForProposedTab: Int?
    /// Current `normalTabs` index of the dragged tab (`nil` for
    /// drags whose source isn't in the local window's `normalTabs`,
    /// e.g. cross-window). Used by the post-move sameSlot check.
    let draggingTabNormalTabsIdx: Int?
}

enum SidebarGroupDropResolver {

    static func shouldResolve(
        proposedItem: Any?,
        isRootBookmarkSectionDrop: Bool = false
    ) -> Bool {
        if isRootBookmarkSectionDrop {
            return false
        }
        return proposedItem == nil
            || proposedItem is SidebarGroupHeaderItem
            || proposedItem is Tab
    }

    /// `true` when the cursor sits on the upper half of `frame`,
    /// where "upper" means visually above midline regardless of
    /// the outline view's flipped coordinate system. Mirrors
    /// `SidebarTabListViewController.swift:1128`.
    static func isUpperHalf(cursorY: CGFloat,
                             frame: CGRect,
                             isFlipped: Bool) -> Bool {
        isFlipped ? (cursorY < frame.midY) : (cursorY > frame.midY)
    }

    /// Classifies a single drag-drop drop position into an intent.
    /// Pure function — no `NSOutlineView` reads, no side effects.
    /// Orchestrates case detection then a post-move sameSlot guard
    /// that mirrors `BrowserState.moveNormalTabLocally:1197-1199`.
    static func resolve(_ ctx: SidebarGroupDropContext) -> SidebarGroupDropIntent {
        let raw = resolveCases(ctx)
        return applySameSlotCheck(raw, ctx: ctx)
    }

    /// All non-sameSlot logic: detects which "case" the drop falls
    /// into (header, group member, ungrouped tab row, root) and
    /// produces the corresponding intent.
    private static func resolveCases(
        _ ctx: SidebarGroupDropContext
    ) -> SidebarGroupDropIntent {
        // case 1: group header
        if let wrapper = ctx.proposedItem as? SidebarGroupHeaderItem,
           let frame = ctx.rowFrameForProposedItem {
            return resolveHeader(wrapper: wrapper, frame: frame, ctx: ctx)
        }
        // case 2 + 3: Tab row (grouped member, or ungrouped normal tab)
        if let tab = ctx.proposedItem as? Tab,
           let frame = ctx.rowFrameForProposedItem {
            if let token = tab.groupToken,
               let memberIdx = ctx.memberIdxInGroupForProposedTab,
               let groupRange = ctx.groupRangeInNormalTabs(token) {
                return resolveGroupMember(
                    token: token,
                    memberIdx: memberIdx,
                    groupLowerBound: groupRange.lowerBound,
                    frame: frame,
                    ctx: ctx)
            }
            // case 3: ungrouped normal tab row.
            if let pos = ctx.normalTabsIdxForProposedTab {
                let upper = isUpperHalf(
                    cursorY: ctx.cursorYInOutline,
                    frame: frame,
                    isFlipped: ctx.outlineIsFlipped)
                return .rootInsert(normalTabsIdx: upper ? pos : pos + 1)
            }
        }
        // case 4: nil proposedItem — drop at outline root.
        if ctx.proposedItem == nil {
            return .rootInsert(
                normalTabsIdx: ctx.resolveNormalTabsIdx(ctx.proposedChildIndex))
        }
        return .rejected(reason: .sameSlot)
    }

    /// Post-process: reject if the resolved intent would land the
    /// dragged tab at exactly its current `normalTabs` slot AND
    /// keep the same group token. Mirrors the post-removal index
    /// math from `BrowserState.moveNormalTabLocally:1197-1199` so
    /// "drop where I started" is a no-op.
    private static func applySameSlotCheck(
        _ intent: SidebarGroupDropIntent,
        ctx: SidebarGroupDropContext
    ) -> SidebarGroupDropIntent {
        // Already-rejected intents pass through unchanged.
        if case .rejected = intent { return intent }
        guard let dragging = ctx.draggingTab else { return intent }
        guard let oldIdx = ctx.draggingTabNormalTabsIdx else { return intent }

        let (newToken, intentIdx): (String?, Int) = {
            switch intent {
            case .joinAtFront(let t, let i):    return (t, i)
            case .reorderInGroup(let t, let i): return (t, i)
            case .rootInsert(let i):            return (nil, i)
            case .rejected:                     return (nil, -1)
            }
        }()
        guard intentIdx >= 0 else { return intent }

        // Mirror moveNormalTabLocally:1197-1199's post-removal math:
        // when oldIdx < intentIdx, removing the source shifts the
        // target down by one.
        let postMoveIdx = (oldIdx < intentIdx)
            ? max(0, intentIdx - 1)
            : intentIdx
        let physicalSame = (oldIdx == postMoveIdx)
        let groupSame    = (dragging.groupToken == newToken)
        if physicalSame && groupSame {
            return .rejected(reason: .sameSlot)
        }
        return intent
    }

    private static func resolveHeader(
        wrapper: SidebarGroupHeaderItem,
        frame: CGRect,
        ctx: SidebarGroupDropContext
    ) -> SidebarGroupDropIntent {
        let token = wrapper.wrappedGroupToken

        guard let groupRange = ctx.groupRangeInNormalTabs(token) else {
            // Group not present in normalTabs — unexpected; reject defensively.
            return .rejected(reason: .sameSlot)
        }

        // Two distinct sub-cases for `(wrapper, ?)` AppKit reports:
        //
        //   (a) Cursor is on the wrapper's row body (drop on header).
        //       AppKit's childIndex is unreliable here — for collapsed
        //       groups it can be `0` or `-1` for the same visual position,
        //       and even for expanded groups any cursor that AppKit
        //       resolves to `(wrapper, -1)` is "drop on header". Use the
        //       cursor.y vs row.midY rule to pick upper/lower half.
        //
        //   (b) Cursor is OUTSIDE the wrapper's row body — i.e., over
        //       the wrapper's expanded children area (or in the gap
        //       between expanded children). AppKit reports
        //       `(wrapper, k)` where `k` is the child-index "insert
        //       before child k". The cursor.y vs wrapper.midY rule is
        //       wrong here (wrapper sits at the TOP of the group, so
        //       cursor in any child-row area is below wrapper.midY and
        //       would be wrongly classified as "lower half →
        //       joinAtFront"). Use the child-index directly:
        //       `normalTabsIdx = lowerBound + k`.
        let cursorOnWrapperRow = ctx.cursorYInOutline >= frame.minY
                              && ctx.cursorYInOutline <= frame.maxY
        let useChildIndex = !cursorOnWrapperRow && ctx.proposedChildIndex >= 0

        if useChildIndex {
            let normalTabsIdx = groupRange.lowerBound + ctx.proposedChildIndex
            // Cross-window into a group is unsupported (Phase 3 boundary).
            if ctx.isCrossWindow {
                return .rejected(reason: .crossWindowGroupJoinUnsupported)
            }
            if ctx.pasteboardKind == .pinnedTab {
                return .rejected(reason: .pinnedNotAllowedInGroup)
            }
            if ctx.pasteboardKind == .phiBookmark {
                return .rejected(reason: .bookmarkNotAllowedInGroup)
            }
            if ctx.draggingTab?.groupToken == token {
                return .reorderInGroup(token: token, normalTabsIdx: normalTabsIdx)
            }
            // Foreign tab joining at the position. Prefer the more-
            // specific .joinAtFront variant when the slot is the
            // group's first; .reorderInGroup otherwise.
            if normalTabsIdx == groupRange.lowerBound {
                return .joinAtFront(token: token, normalTabsIdx: normalTabsIdx)
            }
            return .reorderInGroup(token: token, normalTabsIdx: normalTabsIdx)
        }

        // Drop is on the wrapper's own row — use cursor.y vs midY.
        let upper = isUpperHalf(
            cursorY: ctx.cursorYInOutline,
            frame: frame,
            isFlipped: ctx.outlineIsFlipped)
        let beforeIdx = groupRange.lowerBound
        let firstMemberIdx = groupRange.lowerBound

        if ctx.isCrossWindow && !upper {
            return .rejected(reason: .crossWindowGroupJoinUnsupported)
        }
        if !upper {
            if ctx.pasteboardKind == .pinnedTab {
                return .rejected(reason: .pinnedNotAllowedInGroup)
            }
            if ctx.pasteboardKind == .phiBookmark {
                return .rejected(reason: .bookmarkNotAllowedInGroup)
            }
        }

        if ctx.draggingTab?.groupToken == token {
            return upper
                ? .rootInsert(normalTabsIdx: beforeIdx)
                : .reorderInGroup(token: token, normalTabsIdx: firstMemberIdx)
        }
        return upper
            ? .rootInsert(normalTabsIdx: beforeIdx)
            : .joinAtFront(token: token, normalTabsIdx: firstMemberIdx)
    }

    private static func resolveGroupMember(
        token: String,
        memberIdx: Int,
        groupLowerBound: Int,
        frame: CGRect,
        ctx: SidebarGroupDropContext
    ) -> SidebarGroupDropIntent {
        if ctx.isCrossWindow {
            return .rejected(reason: .crossWindowGroupJoinUnsupported)
        }
        if ctx.pasteboardKind == .pinnedTab {
            return .rejected(reason: .pinnedNotAllowedInGroup)
        }
        if ctx.pasteboardKind == .phiBookmark {
            return .rejected(reason: .bookmarkNotAllowedInGroup)
        }
        let upper = isUpperHalf(
            cursorY: ctx.cursorYInOutline,
            frame: frame,
            isFlipped: ctx.outlineIsFlipped)
        let normalTabsIdx = upper
            ? groupLowerBound + memberIdx
            : groupLowerBound + memberIdx + 1
        return .reorderInGroup(token: token, normalTabsIdx: normalTabsIdx)
    }
}
