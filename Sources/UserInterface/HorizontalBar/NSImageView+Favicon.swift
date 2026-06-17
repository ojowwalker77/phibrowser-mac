// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

@MainActor
enum BookmarkFaviconLoader {
    @discardableResult
    static func loadPrimaryFavicon(for bookmark: Bookmark,
                                   pageURLString: String?,
                                   completion: @escaping (NSImage?) -> Void) -> ProfileScopedFaviconLoadHandle? {
        if let liveFaviconData = bookmark.liveFaviconData,
           let image = NSImage(data: liveFaviconData) {
            completion(image)
            return nil
        }

        return loadFavicon(profileId: bookmark.profileId,
                           pageURLString: pageURLString,
                           snapshotData: bookmark.cachedFaviconData) { [weak bookmark] result in
            completion(result.image)
            if result.source == .chromium, let data = result.data {
                bookmark?.updateCachedFaviconData(data)
            }
        }
    }

    @discardableResult
    static func loadFavicon(profileId: String?,
                            pageURLString: String?,
                            snapshotData: Data? = nil,
                            completion: @escaping (ProfileScopedFaviconResult) -> Void) -> ProfileScopedFaviconLoadHandle? {
        let request = ProfileScopedFaviconRequest(
            profileId: profileId,
            pageURLString: pageURLString,
            snapshotData: snapshotData
        )

        return ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { result in
            completion(result)
        }
    }
}
