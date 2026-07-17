// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct AgentAvatarResponse: Codable {
    enum Source: String, Codable {
        case `default`
        case custom
    }

    let url: String
    let source: Source
    let mimeType: String
    let filename: String
    let updatedAt: String?
}

struct AgentAvatarImagePayload {
    let metadata: AgentAvatarResponse
    let data: Data
}

class APIClient {
    static let shared = APIClient()
    // Lua does not inherit the upstream account or connector services. These
    // features remain unavailable unless an owner-controlled endpoint is
    // supplied explicitly for development.
    private let accountBaseURL = ProcessInfo.processInfo.environment["LUA_ACCOUNT_BASE_URL"]
    private let connectorBaseURL = ProcessInfo.processInfo.environment["LUA_CONNECTOR_BASE_URL"]
    private let token = ""

    func oauthNativeFinishedRedirect(provider: String, result: String) throws -> String {
        var components = URLComponents(
            url: try accountURL("/oauth/native-finished"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "result", value: result),
        ]
        guard let url = components.url else { throw APIError.invalidResponse }
        return url.absoluteString
    }

    func getAccountProfile() async throws -> Response<Profile> {
        let url = try accountURL("/api/auth/profile")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<Profile>.self, from: data)
    }

    func updateProfile(updates: UpdateProfileRequest) async throws -> Response<UpdateProfileResponse> {
        let url = try accountURL("/api/auth/profile")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(updates)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<UpdateProfileResponse>.self, from: data)
    }

    // MARK: - Agent Persona

    func getAgentAvatar() async throws -> AgentAvatarResponse {
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let url = URL(string: "\(baseURL)/api/v1/agent-persona/avatar")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(AgentAvatarResponse.self, from: data)
    }

    // MARK: - Agent Spaces

    /// Notifies phi-agent that the user entered or left an agent Space's window,
    /// or explicitly handed control back to the agent. Informational for the
    /// ownership state machine; failures are non-fatal (the synchronous
    /// Chromium-side agent-mode flip already governs local behavior).
    func setAgentSpacePresence(
        taskId: String,
        userPresent: Bool,
        handback: Bool = false
    ) async throws {
        _ = try await postAgentSpaceAction(
            taskId: taskId,
            action: "presence",
            body: [
                "userPresent": userPresent,
                "handback": handback,
            ]
        )
    }

    /// Hands control of an agent Space to the user (interrupt). `reason` is
    /// typically "user_interrupt".
    func handoffAgentSpace(taskId: String, reason: String) async throws {
        _ = try await postAgentSpaceAction(
            taskId: taskId,
            action: "handoff",
            body: ["reason": reason]
        )
    }

    private func postAgentSpaceAction(
        taskId: String,
        action: String,
        body: [String: Any]
    ) async throws -> (Data, URLResponse) {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await executePhiAgentRequest { baseURL in
            let encoded =
                taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? taskId
            let url = URL(string: "\(baseURL)/api/agent-spaces/\(encoded)/\(action)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        return (data, response)
    }

    /// Sends a request to the local phi-agent, resolving its base URL through
    /// `PhiAgentEndpointResolver` so dynamic port assignment by Sentinel is
    /// honored. On a transport-level error (no listener, refused connection,
    /// timeout) the resolver cache is dropped and the request is rebuilt and
    /// retried exactly once with a freshly resolved endpoint.
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

    func getAgentAvatarImageData() async throws -> AgentAvatarImagePayload {
        let avatar = try await getAgentAvatar()

        if let data = Self.decodeAgentAvatarDataURL(avatar.url) {
            return AgentAvatarImagePayload(metadata: avatar, data: data)
        }

        guard let url = URL(string: avatar.url) else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return AgentAvatarImagePayload(metadata: avatar, data: data)
    }

    static func decodeAgentAvatarDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:"),
              let commaIndex = url.firstIndex(of: ",") else {
            return nil
        }

        let header = url[..<commaIndex]
        let payload = String(url[url.index(after: commaIndex)...])

        if header.localizedCaseInsensitiveContains(";base64") {
            return Data(base64Encoded: payload)
        }

        guard let decodedPayload = payload.removingPercentEncoding else {
            return nil
        }

        return decodedPayload.data(using: .utf8)
    }
    
    // MARK: - Invitation APIs
    
    /// Get user's activation information and invitation details
    func getActivationInfo() async throws -> Response<ActivationInfo> {
        let url = try accountURL("/api/auth/invitation-details")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<ActivationInfo>.self, from: data)
    }
    
    /// Get user's invitation quota information
    func getInviteQuota() async throws -> Response<InviteQuota> {
        let url = try accountURL("/api/auth/invite-quota")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<InviteQuota>.self, from: data)
    }

    /// Get user's invitation codes
    func getInvitationCodes() async throws -> Response<[InvitationCode]> {
        let url = try accountURL("/api/auth/invitation-codes")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<[InvitationCode]>.self, from: data)
    }
    
    /// Create a new invitation code
    func createInvitationCode(request: CreateInvitationCodeRequest) async throws -> Response<InvitationCode> {
        let url = try accountURL("/api/auth/invitation-codes")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<InvitationCode>.self, from: data)
    }
    
    /// Get details of a specific invitation code
    func getInvitationCodeById(codeId: Int) async throws -> Response<InvitationCode> {
        let url = try accountURL("/api/auth/invitation-codes/\(codeId)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<InvitationCode>.self, from: data)
    }
    
    /// Deactivate an invitation code
    func deactivateInvitationCode(codeId: Int) async throws -> Response<String> {
        let url = try accountURL("/api/auth/invitation-codes/\(codeId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<String>.self, from: data)
    }
    
    /// Get or create default invitation code
    func getDefaultInvitationCode() async throws -> Response<InvitationCode> {
        let url = try accountURL("/api/auth/invitation-codes/default")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<InvitationCode>.self, from: data)
    }

    /// Validate an invitation code during account activation
    func validateInvite(request: InviteValidationRequest) async throws -> Response<InviteValidationResponse> {
        let url = try accountURL("/api/invite/validate")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.sessionToken, forHTTPHeaderField: "X-Session-Token")

        let encoder = JSONEncoder()
        let jsonBody = ["invite_code": request.inviteCode]
        urlRequest.httpBody = try encoder.encode(jsonBody)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<InviteValidationResponse>.self, from: data)
    }
    
    // MARK: - Connector APIs

    func getOAuthConnections() async throws -> Response<GetOAuthConnectionsResponse> {
        let url = try accountURL("/api/auth/oauth/connections")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<GetOAuthConnectionsResponse>.self, from: data)
    }

    func getOAuthAuthorization(provider: String, successRedirect: String? = nil, failureRedirect: String? = nil) async throws -> Response<GetOAuthAuthorizationResponse> {
        guard var components = URLComponents(
            url: try accountURL("/api/auth/oauth/authorize/\(provider)"),
            resolvingAgainstBaseURL: false
        ) else { throw APIError.invalidResponse }
        var queryItems: [URLQueryItem] = []
        if let successRedirect {
            queryItems.append(URLQueryItem(name: "success_redirect", value: successRedirect))
        }
        if let failureRedirect {
            queryItems.append(URLQueryItem(name: "failure_redirect", value: failureRedirect))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<GetOAuthAuthorizationResponse>.self, from: data)
    }
    
    /// Create or update a user source
    func createUserSource(request: CreateUserSourceRequest) async throws -> AirbyteResponse<String> {
        let url = try connectorURL("/create-or-update-source")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(AirbyteResponse<String>.self, from: data)
    }
    
    /// Get OAuth consent URL for a connector
    func getConsentUrl(request: GetConsentUrlRequest) async throws -> AirbyteResponse<GetConsentUrlResponse> {
        let url = try connectorURL("/oauth/consent-url")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(AirbyteResponse<GetConsentUrlResponse>.self, from: data)
    }
    
    /// Complete OAuth flow for a connector
    func completeOAuth(request: CompleteOAuthRequest) async throws -> AirbyteResponse<CompleteOAuthResponse> {
        let url = try connectorURL("/oauth/complete-oauth")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(AirbyteResponse<CompleteOAuthResponse>.self, from: data)
    }
    
    /// Create a connection for a source
    func createConnection(request: CreateConnectionRequest) async throws -> AirbyteResponse<String> {
        let url = try connectorURL("/create-connection")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(AirbyteResponse<String>.self, from: data)
    }
    
    func deleteOAuthToken(provider: String) async throws -> Response<DeleteOAuthTokenResponse> {
        let url = try accountURL("/api/auth/oauth/tokens/\(provider)")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "DELETE"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<DeleteOAuthTokenResponse>.self, from: data)
    }

    // MARK: - Feedback V2

    func presignFeedbackV2Attachments(
        _ attachments: [FeedbackV2PresignAttachmentRequest]
    ) async throws -> [FeedbackV2PresignedAttachment] {
        guard attachments.count <= 5 else {
            throw APIError.invalidRequest(message: "Feedback V2 presign supports at most five attachments per request")
        }

        let url = try accountURL("/api/auth/feedback/v2/attachments/presign")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(FeedbackV2PresignRequest(attachments: attachments))

        let response: Response<FeedbackV2PresignData> = try await executeAccountJSONRequest(request)
        guard response.code == 0 else {
            throw APIError.serverError(message: response.message)
        }
        return response.data.attachments
    }

    func uploadFeedbackV2Attachment(
        fileURL: URL,
        mimeType: String,
        presignedAttachment: FeedbackV2PresignedAttachment
    ) async throws {
        guard let url = URL(string: presignedAttachment.uploadURL) else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        if presignedAttachment.headers["Content-Type"] == nil {
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        }
        for (header, value) in presignedAttachment.headers {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    func submitFeedbackV2(_ submitRequest: FeedbackV2SubmitRequest) async throws -> Response<FeedbackV2SubmitData> {
        guard submitRequest.attachments.count <= 5 else {
            throw APIError.invalidRequest(message: "Feedback V2 submit supports at most five attachments")
        }

        let url = try accountURL("/api/auth/feedback/v2/submit")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(submitRequest)

        let response: Response<FeedbackV2SubmitData> = try await executeAccountJSONRequest(request)
        guard response.code == 0 else {
            throw APIError.serverError(message: response.message)
        }
        return response
    }

    private func accountURL(_ path: String) throws -> URL {
        try Self.configuredURL(
            baseURL: accountBaseURL,
            path: path,
            service: "Lua account services",
            environmentVariable: "LUA_ACCOUNT_BASE_URL"
        )
    }

    private func connectorURL(_ path: String) throws -> URL {
        try Self.configuredURL(
            baseURL: connectorBaseURL,
            path: path,
            service: "Lua connector services",
            environmentVariable: "LUA_CONNECTOR_BASE_URL"
        )
    }

    private static func configuredURL(
        baseURL: String?,
        path: String,
        service: String,
        environmentVariable: String
    ) throws -> URL {
        guard let baseURL,
              var components = URLComponents(string: baseURL),
              components.scheme == "https" || components.scheme == "http",
              components.host != nil else {
            throw APIError.serviceUnavailable(
                service: service,
                configuration: environmentVariable
            )
        }

        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + path
        guard let url = components.url else { throw APIError.invalidResponse }
        return url
    }

    private func executeAccountJSONRequest<T: Codable>(_ request: URLRequest) async throws -> Response<T> {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<T>.self, from: data)
    }
}

enum APIError: Error {
    case invalidResponse
    case invalidRequest(message: String)
    case httpError(statusCode: Int)
    case decodingError
    case serverError(message: String)
    case serviceUnavailable(service: String, configuration: String)
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let service, let configuration):
            return "\(service) are unavailable in this build. Configure an owner-controlled endpoint with \(configuration)."
        case .invalidRequest(let message), .serverError(let message):
            return message
        case .httpError(let statusCode):
            return "The service returned HTTP \(statusCode)."
        case .invalidResponse:
            return "The service returned an invalid response."
        case .decodingError:
            return "The service response could not be decoded."
        }
    }
}
