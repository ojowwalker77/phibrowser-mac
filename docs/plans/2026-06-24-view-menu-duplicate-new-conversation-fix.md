# Fix: duplicate "New Conversation" item in the View menu

Date: 2026-06-24

## Background and symptom

The View menu showed two "New Conversation" items: one at the bottom (below Toggle Chatbar, the expected position) and another stranded below the "Developer" submenu and above the "Layout Mode" section. With repeated menu rebuilds the stale items could keep accumulating, and extra separators piled up above Layout Mode as well.

## Root cause

In `Sources/Application/AppController+Menu.swift`, `hookAndRebuildMainMenu()` observes changes to `NSApp.mainMenu`. Every time Chromium rebuilds the main menu, it re-appends Phi's custom items (Layout Mode, Bookmark Bar, Toggle Sidebar/Chatbar, New Conversation, Spaces, etc.) to the View submenu.

To avoid appending duplicates, the rebuild first removes the previously added custom items by tag via `submenu.items.removeAll { ... }`, then re-appends them with `addItem`. The bug had two parts:

- The `removeAll` tag list **omitted** `CommandWrapper.PHI_NEW_CONVERSATION.rawValue`, so the old New Conversation item was never removed.
- Like the other custom items, New Conversation is `addItem`-ed to the end of the submenu. `removeAll` deleted the tagged items surrounding it (Toggle Sidebar/Chatbar, Layout, Bookmark, Spaces, etc.) but left the untagged old New Conversation item in place (right after the native "Developer" item), while a fresh full set was appended at the end. The stale item therefore stayed below "Developer" and above the newly appended Layout Mode section.
- Similarly, the three `NSMenuItem.separator()` items inside the Phi section had no tag (tag 0) and were not in the `removeAll` list, so they accumulated on every rebuild.

The other custom items (Toggle Sidebar/Chatbar, etc.) did not duplicate precisely because their tags were already in the `removeAll` list, achieving remove-then-add.

## Fix

In `AppController+Menu.swift`:

1. Added a dedicated separator tag constant `viewMenuPhiSectionSeparatorTag = 500023`.
2. Added two entries to the View menu `removeAll` list:
   - `item.tag == CommandWrapper.PHI_NEW_CONVERSATION.rawValue`
   - `item.tag == AppController.viewMenuPhiSectionSeparatorTag`
3. Tagged the three previously untagged separators in the Phi section (top separator, before Bookmark Bar, before Toggle Sidebar) with `viewMenuPhiSectionSeparatorTag` so they are cleaned up by `removeAll` on rebuild.

With this, each rebuild removes the previous New Conversation item and Phi-section separators before re-appending them, keeping them unique and their position stable.

## Open issues

None. The remaining Phi custom items already achieve remove-then-add through their own tags; this change only fills in the two previously omitted categories (New Conversation and the section separators).
