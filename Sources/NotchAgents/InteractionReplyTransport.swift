import Foundation
import Security

protocol InteractionReplyTransporting: Sendable {
    func respond(
        to interaction: AgentInteraction,
        decision: PermissionDecision,
        instruction: String?
    ) async throws
    func respond(
        to interaction: AgentInteraction,
        answers: [String: QuestionAnswer]
    ) async throws
}

extension InteractionReplyTransporting {
    func respond(
        to interaction: AgentInteraction,
        answers: [String: QuestionAnswer]
    ) async throws {
        throw InteractionReplyTransportError.unsupportedTransport
    }
}

enum InteractionReplyTransportError: LocalizedError, Equatable {
    case invalidEndpoint
    case missingRoute
    case unsupportedTransport
    case instructionUnsupported
    case invalidResponse
    case rejected(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The approval service must be an HTTP endpoint on this Mac."
        case .missingRoute:
            "This approval no longer has a response route."
        case .unsupportedTransport:
            "This approval transport is not supported."
        case .instructionUnsupported:
            "T3 Code can accept or decline this request, but cannot attach an instruction."
        case .invalidResponse:
            "The approval service returned an invalid response."
        case .rejected(let statusCode):
            "The approval service rejected the response (HTTP \(statusCode))."
        }
    }
}

enum T3AccessTokenError: LocalizedError, Equatable {
    case missing
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missing:
            "T3 Code is not connected to Notch Agents. Connect it in Settings → Agents."
        case .keychain(let status):
            "Notch Agents could not read the T3 Code access token from Keychain (status \(status))."
        }
    }
}

enum T3PairingError: LocalizedError, Equatable {
    case invalidEndpoint
    case missingCredential
    case invalidResponse
    case missingRequiredScope
    case rejected(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The T3 Code pairing service must be an HTTP endpoint on this Mac."
        case .missingCredential:
            "Enter the one-time pairing credential from T3 Code."
        case .invalidResponse:
            "T3 Code returned an invalid pairing response."
        case .missingRequiredScope:
            "T3 Code did not grant permission to respond to approvals."
        case .rejected(let statusCode):
            "T3 Code rejected the pairing credential (HTTP \(statusCode))."
        }
    }
}

struct T3KeychainAccessTokenStore: Sendable {
    static let service = "app.notchagents.t3code"
    static let account = "orchestration"

    func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw T3AccessTokenError.missing
        }
        guard status == errSecSuccess else {
            throw T3AccessTokenError.keychain(status: status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw T3AccessTokenError.missing
        }
        return token
    }

    func save(_ token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw T3AccessTokenError.missing }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw T3AccessTokenError.keychain(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw T3AccessTokenError.keychain(status: status)
        }
    }

    func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw T3AccessTokenError.keychain(status: status)
        }
    }
}

struct T3PairingCredentialExchanger: Sendable {
    typealias RequestSender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let tokenExchangeGrant =
        "urn:ietf:params:oauth:grant-type:token-exchange"
    private static let bootstrapTokenType =
        "urn:t3:params:oauth:token-type:environment-bootstrap"
    private static let accessTokenType =
        "urn:ietf:params:oauth:token-type:access_token"
    static let requiredScope = "orchestration:operate"

    private let endpoint: URL
    private let send: RequestSender

    init(
        endpoint: URL = URL(string: "http://127.0.0.1:3773")!,
        send: @escaping RequestSender = { try await URLSession.shared.data(for: $0) }
    ) throws {
        guard T3ApprovalReplyTransport.isSafeLoopbackEndpoint(endpoint) else {
            throw T3PairingError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.send = send
    }

    /// Exchanges a user-supplied one-time credential without retaining it.
    /// The caller is responsible for persisting the returned access token.
    func exchange(_ pairingCredential: String) async throws -> String {
        let credential = pairingCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            throw T3PairingError.missingCredential
        }

        var request = URLRequest(url: endpoint.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formBody([
            ("grant_type", Self.tokenExchangeGrant),
            ("subject_token", credential),
            ("subject_token_type", Self.bootstrapTokenType),
            ("requested_token_type", Self.accessTokenType),
            ("scope", Self.requiredScope),
            ("client_label", "Notch Agents"),
            ("client_device_type", "desktop"),
            ("client_os", "macOS"),
        ])

        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else {
            throw T3PairingError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw T3PairingError.rejected(statusCode: response.statusCode)
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["token_type"] as? String == "Bearer",
              result["issued_token_type"] as? String == Self.accessTokenType,
              let accessToken = (result["access_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty,
              let scopes = result["scope"] as? String else {
            throw T3PairingError.invalidResponse
        }
        guard scopes.split(whereSeparator: \.isWhitespace)
            .contains(Substring(Self.requiredScope)) else {
            throw T3PairingError.missingRequiredScope
        }
        return accessToken
    }

    private static func formBody(_ values: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}

struct T3ApprovalReplyTransport: InteractionReplyTransporting {
    typealias AccessTokenProvider = @Sendable () async throws -> String
    typealias RequestSender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let endpoint: URL
    private let accessToken: AccessTokenProvider
    private let send: RequestSender
    private let now: @Sendable () -> Date
    private let makeCommandID: @Sendable () -> String

    init(
        endpoint: URL = URL(string: "http://127.0.0.1:3773")!,
        accessToken: @escaping AccessTokenProvider,
        send: @escaping RequestSender = { try await URLSession.shared.data(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        makeCommandID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) throws {
        guard Self.isSafeLoopbackEndpoint(endpoint) else {
            throw InteractionReplyTransportError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.accessToken = accessToken
        self.send = send
        self.now = now
        self.makeCommandID = makeCommandID
    }

    func respond(
        to interaction: AgentInteraction,
        decision: PermissionDecision,
        instruction: String?
    ) async throws {
        guard let route = interaction.replyRoute,
              route.transport == .t3Orchestration else {
            throw InteractionReplyTransportError.missingRoute
        }
        if let instruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            throw InteractionReplyTransportError.instructionUnsupported
        }

        let token = try await accessToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw InteractionReplyTransportError.invalidResponse
        }

        var request = URLRequest(
            url: endpoint.appendingPathComponent("api/orchestration/dispatch")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: approvalCommand(
            route: route,
            decision: decision
        ))

        try await sendAndValidate(request)
    }

    func respond(
        to interaction: AgentInteraction,
        answers: [String: QuestionAnswer]
    ) async throws {
        guard let route = interaction.replyRoute,
              route.transport == .t3Orchestration else {
            throw InteractionReplyTransportError.missingRoute
        }
        let encodedAnswers = Self.encodeAnswers(answers)
        guard !encodedAnswers.isEmpty else {
            throw InteractionReplyTransportError.invalidResponse
        }

        let token = try await accessToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw InteractionReplyTransportError.invalidResponse
        }

        var request = URLRequest(
            url: endpoint.appendingPathComponent("api/orchestration/dispatch")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "type": "thread.user-input.respond",
            "commandId": makeCommandID(),
            "threadId": route.threadID,
            "requestId": route.requestID,
            "answers": encodedAnswers,
            "createdAt": Self.iso8601(now()),
        ])

        try await sendAndValidate(request)
    }

    private func sendAndValidate(_ request: URLRequest) async throws {
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else {
            throw InteractionReplyTransportError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw InteractionReplyTransportError.rejected(statusCode: response.statusCode)
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["sequence"] is NSNumber else {
            throw InteractionReplyTransportError.invalidResponse
        }
    }

    private func approvalCommand(
        route: InteractionReplyRoute,
        decision: PermissionDecision
    ) -> [String: Any] {
        [
            "type": "thread.approval.respond",
            "commandId": makeCommandID(),
            "threadId": route.threadID,
            "requestId": route.requestID,
            "decision": decision == .allow ? "accept" : "decline",
            "createdAt": Self.iso8601(now()),
        ]
    }

    private static func encodeAnswers(
        _ answers: [String: QuestionAnswer]
    ) -> [String: Any] {
        answers.reduce(into: [String: Any]()) { result, item in
            let text = item.value.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var values = item.value.selectedValues
            if let text, !text.isEmpty, !values.contains(text) {
                values.append(text)
            }
            guard !values.isEmpty else { return }
            result[item.key] = values.count == 1 ? values[0] : values
        }
    }

    static func isSafeLoopbackEndpoint(_ endpoint: URL) -> Bool {
        guard endpoint.scheme == "http",
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/" else {
            return false
        }
        switch endpoint.host?.lowercased() {
        case "127.0.0.1", "::1", "localhost":
            return true
        default:
            return false
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
