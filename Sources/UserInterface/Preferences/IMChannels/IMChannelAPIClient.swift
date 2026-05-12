// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// MARK: - Data Models

struct TelegramPrepareResponse: Codable {
    let agent: AgentInfo
    let pairing: PairingSession

    struct AgentInfo: Codable {
        let id: String
        let token: String?
        let isNew: Bool
    }
}

struct PairingSession: Codable {
    let sessionId: String
    let deepLink: String?
    let expiresAt: Int
    let status: String
    let pairedAt: Int?
    let platform: String?
    let platformUserId: String?
    let platformUsername: String?
    let platformName: String?
}

struct ChannelPairing: Codable, Identifiable {
    let id: String
    let platform: String
    let platformUserId: String
    let platformUsername: String?
    let platformName: String?
    let pairedAt: String
    let agentId: String?
    let channelId: String?
    let localStatus: String?
}

struct CustomBotChannel: Codable, Identifiable {
    // CouchDB uses _id, but Swift prefers `id`
    let _id: String
    let channelType: String
    let name: String
    let enabled: Bool
    let config: [String: AnyCodableValue]?
    let status: String
    let statusMessage: String?
    let isRunning: Bool
    let botUsername: String?
    let createdAt: Double?
    let updatedAt: Double?

    var id: String { _id }
}

struct CustomBotListResponse: Codable {
    let channels: [CustomBotChannel]
    let connected: Bool
}

struct PairingsListResponse: Codable {
    let pairings: [ChannelPairing]?
}

/// Lightweight wrapper so arbitrary JSON values survive Codable round-trips.
enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

struct AgentPersonaResponse: Codable {
    let variables: PersonaVariables?

    struct PersonaVariables: Codable {
        let name: String?
    }
}

// MARK: - API Client

final class IMChannelAPIClient {
    static let shared = IMChannelAPIClient()

    private var token: String {
        AuthManager.shared.getAccessTokenSyncly() ?? ""
    }

    private func authorizedRequest(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: Agent Persona

    func fetchAgentPersona() async throws -> AgentPersonaResponse {
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/v1/agent-persona")!
            return self.authorizedRequest(url)
        }
        try validateResponse(response)
        return try JSONDecoder().decode(AgentPersonaResponse.self, from: data)
    }

    // MARK: Official Bot

    func prepareTelegram() async throws -> TelegramPrepareResponse {
        AppLogDebug("[IMChannelAPI] POST /api/telegram/prepare — token length: \(token.count)")
        let body = try JSONEncoder().encode([String: String]())
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/telegram/prepare")!
            var request = self.authorizedRequest(url, method: "POST")
            request.httpBody = body
            return request
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogDebug("[IMChannelAPI] prepareTelegram response: \(statusCode), body: \(String(data: data.prefix(500), encoding: .utf8) ?? "?")")
        try validateResponse(response)
        return try JSONDecoder().decode(TelegramPrepareResponse.self, from: data)
    }

    func getPairingStatus(sessionId: String) async throws -> PairingSession {
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/telegram/pairings/\(sessionId)")!
            return self.authorizedRequest(url)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "?"
        AppLogDebug("[IMChannelAPI] GET /api/telegram/pairings/\(sessionId) → \(statusCode): \(bodyPreview)")
        try validateResponse(response)
        return try JSONDecoder().decode(PairingSession.self, from: data)
    }

    func listPairings() async throws -> [ChannelPairing] {
        AppLogDebug("[IMChannelAPI] GET /api/pairings")
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/pairings")!
            return self.authorizedRequest(url)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogDebug("[IMChannelAPI] listPairings response: \(statusCode)")
        try validateResponse(response)
        let result = try JSONDecoder().decode(PairingsListResponse.self, from: data)
        return result.pairings ?? []
    }

    func disconnectPairing(id: String) async throws {
        let (_, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/pairings/\(id)")!
            return self.authorizedRequest(url, method: "DELETE")
        }
        try validateResponse(response)
    }

    // MARK: Custom Bot

    func listCustomBotChannels() async throws -> CustomBotListResponse {
        AppLogDebug("[IMChannelAPI] GET /api/custom-bot/channels")
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/custom-bot/channels")!
            return self.authorizedRequest(url)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogDebug("[IMChannelAPI] listCustomBotChannels response: \(statusCode), body: \(String(data: data.prefix(300), encoding: .utf8) ?? "?")")
        try validateResponse(response)
        return try JSONDecoder().decode(CustomBotListResponse.self, from: data)
    }

    func createCustomBotChannel(botToken: String, enabled: Bool) async throws -> CustomBotChannel {
        let body = try JSONSerialization.data(withJSONObject: ["botToken": botToken, "enabled": enabled] as [String: Any])
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/custom-bot/channels")!
            var request = self.authorizedRequest(url, method: "POST")
            request.httpBody = body
            return request
        }
        try validateResponse(response)
        return try JSONDecoder().decode(CustomBotChannel.self, from: data)
    }

    func updateCustomBotChannel(id: String, enabled: Bool? = nil, botToken: String? = nil) async throws -> CustomBotChannel {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var bodyDict: [String: Any] = [:]
        if let enabled { bodyDict["enabled"] = enabled }
        if let botToken { bodyDict["botToken"] = botToken }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/custom-bot/channels/\(encoded)")!
            var request = self.authorizedRequest(url, method: "PUT")
            request.httpBody = body
            return request
        }
        try validateResponse(response)
        return try JSONDecoder().decode(CustomBotChannel.self, from: data)
    }

    func verifyBotToken(botToken: String? = nil, channelId: String? = nil) async throws -> (success: Bool, error: String?) {
        var bodyDict: [String: String] = [:]
        if let botToken { bodyDict["botToken"] = botToken }
        if let channelId { bodyDict["channelId"] = channelId }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        AppLogDebug("[IMChannelAPI] POST /api/custom-bot/verify")
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/custom-bot/verify")!
            var request = self.authorizedRequest(url, method: "POST")
            request.httpBody = body
            return request
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogDebug("[IMChannelAPI] verify response: \(statusCode)")
        try validateResponse(response)
        struct VerifyResult: Codable { let success: Bool; let error: String? }
        let result = try JSONDecoder().decode(VerifyResult.self, from: data)
        return (result.success, result.error)
    }

    func deleteCustomBotChannel(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let (_, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/custom-bot/channels/\(encoded)")!
            return self.authorizedRequest(url, method: "DELETE")
        }
        try validateResponse(response)
    }

    // MARK: Helpers

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw IMChannelAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw IMChannelAPIError.httpError(statusCode: http.statusCode)
        }
    }

    /// Sends a request to the local phi-agent, resolving the base URL
    /// dynamically through `PhiAgentEndpointResolver` (Sentinel may remap
    /// phi-agent's port). On a transport-level failure the resolver cache is
    /// invalidated and the request is rebuilt against a freshly resolved
    /// endpoint and retried exactly once.
    private func executePhiAgentRequest(
        build: (_ baseURL: String) -> URLRequest
    ) async throws -> (Data, URLResponse) {
        let firstBase = await PhiAgentEndpointResolver.shared.currentBaseURL()
        do {
            return try await URLSession.shared.data(for: build(firstBase))
        } catch let error as URLError where Self.isPhiAgentTransportError(error) {
            await PhiAgentEndpointResolver.shared.invalidate()
            let retryBase = await PhiAgentEndpointResolver.shared.currentBaseURL()
            if retryBase == firstBase {
                throw error
            }
            return try await URLSession.shared.data(for: build(retryBase))
        }
    }

    private static func isPhiAgentTransportError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut:
            return true
        default:
            return false
        }
    }
}

enum IMChannelAPIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from phi-agent"
        case .httpError(let code): return "phi-agent returned HTTP \(code)"
        }
    }
}
