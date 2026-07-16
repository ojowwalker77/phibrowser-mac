// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

final class CommonMessageRouter {
    static let shared = CommonMessageRouter()
    private let messanger: ExtensionMessagingProtocol
    
    init(messanger: ExtensionMessagingProtocol = ExtensionMessaging.shared) {
        self.messanger = messanger
    }

    func handle(_ context: ExtensionMessageContext) -> String? {
        switch context.type {
        case "getWindowTheme":
            WindowThemeMessageRouter.shared.handleGetWindowTheme(context)
            return nil
        default:
            AppLogDebug("[CommonMessage] Unhandled message type: \(context.type)")
            return nil
        }
    }
    
}
