// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct EmojiCatalog: Decodable {
    struct Group: Decodable, Identifiable, Hashable {
        let name: String
        let items: [EmojiItem]

        var id: String { name }
    }

    let version: String
    let date: String
    let source: String
    let groups: [Group]

    static let shared = EmojiCatalog.loadFromBundle()

    var allItems: [EmojiItem] {
        groups.flatMap(\.items)
    }

    func text(for id: String) -> String? {
        for item in allItems {
            if item.id == id {
                return item.text
            }
            if let variant = item.skinVariants.first(where: { $0.id == id }) {
                return variant.text
            }
        }
        return nil
    }

    private static func loadFromBundle() -> EmojiCatalog {
        let url = Bundle.main.url(
            forResource: "emoji-catalog",
            withExtension: "json",
            subdirectory: "Emoji"
        ) ?? Bundle.main.url(
            forResource: "emoji-catalog",
            withExtension: "json"
        )

        guard let url else {
            AppLogError("[EmojiCatalog] emoji-catalog.json is missing from the bundle")
            return .empty
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(EmojiCatalog.self, from: data)
        } catch {
            AppLogError("[EmojiCatalog] Failed to load emoji catalog: \(error)")
            return .empty
        }
    }

    private static let empty = EmojiCatalog(
        version: "",
        date: "",
        source: "",
        groups: []
    )
}

struct EmojiItem: Decodable, Identifiable, Hashable {
    let id: String
    let text: String
    let name: String
    let subgroup: String
    let skinVariants: [EmojiVariant]

    var hasSkinVariants: Bool {
        !skinVariants.isEmpty
    }
}

struct EmojiVariant: Decodable, Identifiable, Hashable {
    let id: String
    let text: String
    let name: String
}
