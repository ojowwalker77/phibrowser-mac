// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Serializes a Space's bookmark tree into the Netscape bookmark file format
/// (`NETSCAPE-Bookmark-file-1`) understood by Chrome, Firefox, Safari, and
/// Edge. Pure string building — file writing and the save panel live with the
/// menu action in `AppController`.
enum BookmarkHTMLExporter {
    static func htmlDocument(for bookmarks: [Bookmark]) -> String {
        var lines: [String] = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file.",
            "     It will be read and overwritten.",
            "     DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]
        for bookmark in bookmarks {
            appendNode(bookmark, depth: 1, into: &lines)
        }
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendNode(_ bookmark: Bookmark, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "    ", count: depth)
        if bookmark.isFolder {
            lines.append("\(indent)<DT><H3\(folderDateAttributes(for: bookmark))>\(escaped(bookmark.title))</H3>")
            lines.append("\(indent)<DL><p>")
            for child in bookmark.children {
                appendNode(child, depth: depth + 1, into: &lines)
            }
            lines.append("\(indent)</DL><p>")
            return
        }
        var attributes = " HREF=\"\(escaped(bookmark.url ?? ""))\"" + addDateAttribute(for: bookmark)
        if let favicon = bookmark.cachedFaviconData {
            attributes += " ICON=\"data:image/png;base64,\(favicon.base64EncodedString())\""
        }
        lines.append("\(indent)<DT><A\(attributes)>\(escaped(bookmark.title))</A>")
        // A split bookmark carries a second URL the generic format cannot
        // express on one entry — flatten it into an adjacent plain entry.
        // Its title falls back to the primary title (suppressed-duplicate
        // convention at creation), then to the URL itself.
        if let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty {
            let fallback = bookmark.title.isEmpty ? secondaryURL : bookmark.title
            let secondaryTitle = (bookmark.secondaryTitle?.isEmpty == false)
                ? bookmark.secondaryTitle! : fallback
            let secondaryAttributes = " HREF=\"\(escaped(secondaryURL))\"" + addDateAttribute(for: bookmark)
            lines.append("\(indent)<DT><A\(secondaryAttributes)>\(escaped(secondaryTitle))</A>")
        }
    }

    private static func addDateAttribute(for bookmark: Bookmark) -> String {
        guard let created = bookmark.createdDate else { return "" }
        return " ADD_DATE=\"\(Int(created.timeIntervalSince1970))\""
    }

    /// URL entries carry ADD_DATE only: LAST_MODIFIED means "last edit" in
    /// the format, while `updatedDate` is also bumped by bookmark opens
    /// (LocalStore.updateLastSeen). Chrome's exporter omits it on entries
    /// too. Folder rows are only touched by real edits, so folders keep it.
    private static func folderDateAttributes(for bookmark: Bookmark) -> String {
        var attributes = addDateAttribute(for: bookmark)
        if let updated = bookmark.updatedDate {
            attributes += " LAST_MODIFIED=\"\(Int(updated.timeIntervalSince1970))\""
        }
        return attributes
    }

    /// Default export filename: `Phi-Bookmarks-<SpaceName>-<yyyy-MM-dd>.html`,
    /// spaces-free throughout. Whitespace and the filesystem-hostile `/` and
    /// `:` in the Space name become hyphens; runs collapse to one.
    static func defaultFilename(spaceName: String, date: Date) -> String {
        var collapsed = ""
        for character in spaceName {
            let mapped: Character =
                (character == "/" || character == ":" || character.isWhitespace) ? "-" : character
            if mapped == "-", collapsed.hasSuffix("-") { continue }
            collapsed.append(mapped)
        }
        let name = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let segment = name.isEmpty ? "Space" : name

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Lua-Bookmarks-\(segment)-\(formatter.string(from: date)).html"
    }

    /// Escapes text for use in HTML body text and double-quoted attributes.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
