// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

protocol SearchTabsTextFieldKeyDelegate: AnyObject {
    func searchTabsTextFieldDidMoveDown(_ textField: SearchTabsTextField) -> Bool
    func searchTabsTextFieldDidMoveUp(_ textField: SearchTabsTextField) -> Bool
    func searchTabsTextFieldDidConfirm(_ textField: SearchTabsTextField) -> Bool
    func searchTabsTextFieldDidCancel(_ textField: SearchTabsTextField) -> Bool
}

final class SearchTabsTextField: NSTextField {
    weak var keyDelegate: SearchTabsTextFieldKeyDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = NSFont.systemFont(ofSize: 18, weight: .regular)
        textColor = .labelColor
        placeholderString = NSLocalizedString(
            "Search Tabs",
            comment: "Search Tabs - Placeholder text for the native tab search field"
        )
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.wraps = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            if keyDelegate?.searchTabsTextFieldDidMoveDown(self) == true { return }
        case 126:
            if keyDelegate?.searchTabsTextFieldDidMoveUp(self) == true { return }
        case 36, 76:
            if keyDelegate?.searchTabsTextFieldDidConfirm(self) == true { return }
        case 53:
            if keyDelegate?.searchTabsTextFieldDidCancel(self) == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }
}
