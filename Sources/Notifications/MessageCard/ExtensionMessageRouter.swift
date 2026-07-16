// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct ExtensionMessageContext {
    let type: String
    let payload: String
    let requestId: String
    /// The sender's extension id, or a synthetic id for non-extension origins
    /// ("cdp" for the PhiAgentSpace DevTools tunnel, "debug-extension" for the
    /// debug panel). Empty when the bridge didn't attribute a sender.
    let senderId: String
}

typealias ExtensionMessageHandler = (ExtensionMessageContext) -> String?

final class ExtensionMessageRouter {
    static let shared = ExtensionMessageRouter()

    private var handlers: [String: ExtensionMessageHandler] = [:]
    private var configured = false

    func register(type: String, handler: @escaping ExtensionMessageHandler) {
        handlers[type] = handler
    }

    func handle(type: String, payload: String, requestId: String, senderId: String = "") -> String? {
        configureIfNeeded()
        let context = ExtensionMessageContext(type: type, payload: payload, requestId: requestId, senderId: senderId)
        if let handler = handlers[type] {
            return handler(context)
        }
        return CommonMessageRouter.shared.handle(context)
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
    }
}
