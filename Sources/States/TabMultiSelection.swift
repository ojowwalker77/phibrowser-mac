// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Temporary, window-scoped multi-selection of tabs.
/// Membership only; ordering is derived from the authoritative tab list.
struct TabMultiSelection: Equatable {
    private(set) var guids: Set<Int>

    /// Single feature gate for temporary multi-selection availability.
    static let isEnabled = false

    static let empty = TabMultiSelection(guids: [])

    var isActive: Bool { !guids.isEmpty }

    func contains(_ guid: Int) -> Bool { guids.contains(guid) }

    mutating func toggle(_ guid: Int) {
        if guids.contains(guid) {
            guids.remove(guid)
        } else {
            guids.insert(guid)
        }
    }

    /// Drops any guids not present in `valid`, e.g. after their tabs close.
    mutating func formIntersection(_ valid: Set<Int>) {
        guids.formIntersection(valid)
    }
}
