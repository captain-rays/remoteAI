import CryptoKit
import Foundation

/// Minimal URLSession transport for a paired Agent. REST is used for the
/// read-only catalog/diagnostics APIs; mutating conversation requests travel
/// over the encrypted websocket required by GatewaySession.
public actor RemoteAgentClient: AgentClient {
    public nonisolated let events: AsyncStream<EventEnvelope>

    private let store: SecretStore
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var keys: SessionKeys?
    private var sendCounter: UInt64 = 0
    private let continuation: AsyncStream<EventEnvelope>.Continuation

    public init(store: SecretStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
        var captured: AsyncStream<EventEnvelope>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.continuation = captured
    }

    public static func endpoint(origin: URL, path: String) throws -> URL {
        guard ["http", "https"].contains(origin.scheme?.lowercased()), origin.host != nil,
            origin.user == nil, origin.password == nil
        else { throw AgentClientError.invalidRequest("invalid agent origin") }
        return origin.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// Streaming sends keep the socket alive for deltas and close only after
    /// the terminal turn event. Kept pure so this lifecycle rule is tested
    /// without making a network connection.
    public static func shouldKeepSocket(after event: EventEnvelope) -> Bool {
        event.rawType != "turn.completed" && event.rawType != "turn.failed"
    }

    /// Validates counters independently for each websocket connection. The
    /// gateway starts outbound counters at one for every new connection.
    public static func responseCountersAreScopedToConnections(
        _ connections: [[UInt64]]
    ) -> Bool {
        connections.allSatisfy { counters in
            var guardState = ReplayGuard()
            return counters.allSatisfy { guardState.accept(counter: $0) }
        }
    }

    public static func socketFailureMessage(stage: String) -> String {
        switch stage {
        case "connect": return "The Mac WebSocket could not connect."
        case "send": return "The message could not reach the Mac."
        case "receive": return "The Mac WebSocket closed before responding."
        default: return "The secure WebSocket failed."
        }
    }

    public static func makeEncryptedFrame(
        plaintext: Data,
        counter: UInt64,
        routing: RoutingMetadata,
        key: SymmetricKey,
        direction: CryptoDirection = .phoneToMac
    ) throws -> EncryptedFrame {
        let ciphertext = try CryptoBox(key: key, direction: direction).seal(
            plaintext, counter: counter, aad: routing.canonicalData()
        )
        return EncryptedFrame(
            counter: counter,
            routing: routing,
            ciphertext: ciphertext.base64EncodedString()
        )
    }

    private func identity() throws -> (DeviceIdentity, P256.KeyAgreement.PrivateKey, String) {
        guard let identity = try store.load() else { throw AgentClientError.notPaired }
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: identity.privateKey)
        let deviceId = RemotePairingService.deterministicDeviceId(
            publicKey: privateKey.publicKey.x963Representation
        )
        return (identity, privateKey, deviceId)
    }

    private func originAndIdentity() throws -> (URL, DeviceIdentity, String) {
        let (identity, _, deviceId) = try identity()
        guard let origin = URL(string: identity.origin) else {
            throw AgentClientError.invalidRequest("invalid paired origin")
        }
        return (origin, identity, deviceId)
    }

    private func rest<T: Decodable>(_ method: String, path: String, query: [URLQueryItem] = []) async throws -> T {
        let (origin, _, deviceId) = try originAndIdentity()
        var components = URLComponents(url: try Self.endpoint(origin: origin, path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(deviceId, forHTTPHeaderField: "x-remoteai-device")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentClientError.transport("invalid response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentClientError.transport("http_\(http.statusCode)")
        }
        do { return try ProtocolCoding.decoder.decode(T.self, from: data) }
        catch { throw AgentClientError.transport("decode_failed") }
    }

    public func providerStatus() async throws -> [ProviderStatus] {
        struct Health: Decodable { let status: ProviderStatus }
        struct Report: Decodable { let providers: [Health] }
        let report: Report = try await rest("GET", path: "v1/diagnostics")
        return report.providers.map(\.status)
    }

    public func listDailyConversations(provider: ProviderId) async throws -> [ConversationSummary] {
        try await rest("GET", path: "v1/conversations/daily", query: [.init(name: "provider", value: provider.rawValue)])
    }

    public func listProjects(provider: ProviderId) async throws -> [ProjectSummary] {
        try await rest("GET", path: "v1/projects", query: [.init(name: "provider", value: provider.rawValue)])
    }

    public func listProjectConversations(provider: ProviderId, projectId: String) async throws -> [ConversationSummary] {
        try await rest("GET", path: "v1/projects/\(projectId)/conversations", query: [.init(name: "provider", value: provider.rawValue)])
    }

    public func history(provider: ProviderId, conversationId: String, cursor: String?, limit: Int) async throws -> HistoryPage { throw AgentClientError.transport("history requires GatewaySession") }

    private struct StartPayload: Codable, Sendable { let provider: ProviderId; let kind: ConversationKind; let cwd: String? }

    public struct StartResponse: Decodable, Sendable, Hashable {
        public let conversationId: String
        public let provider: ProviderId

        public init(conversationId: String, provider: ProviderId) {
            self.conversationId = conversationId
            self.provider = provider
        }
    }

    public static func conversationSummary(
        from response: StartResponse,
        kind: ConversationKind,
        cwd: String?,
        now: Date
    ) -> ConversationSummary {
        ConversationSummary(
            id: response.conversationId,
            provider: response.provider,
            kind: kind,
            title: "New \(response.provider.displayName) conversation",
            projectPath: kind == .project ? cwd : nil,
            updatedAt: now,
            status: .running
        )
    }

    public func startConversation(provider: ProviderId, kind: ConversationKind, cwd: String?) async throws -> ConversationSummary {
        let result: StartResponse = try await request(
            type: .conversationStart,
            conversationId: nil,
            payload: StartPayload(provider: provider, kind: kind, cwd: cwd),
            response: StartResponse.self
        )
        return Self.conversationSummary(from: result, kind: kind, cwd: cwd, now: Date())
    }

    public func resumeConversation(provider: ProviderId, conversationId: String) async throws { throw AgentClientError.transport("resume requires GatewaySession") }

    public func send(provider: ProviderId, conversationId: String, text: String) async throws {
        _ = try await request(
            type: .conversationSend,
            conversationId: conversationId,
            payload: ConversationSendPayload(
                provider: provider, conversationId: conversationId, text: text
            ),
            response: EmptyResponse.self,
            waitForTurnCompletion: true
        )
    }

    public func interrupt(provider: ProviderId, conversationId: String) async throws { throw AgentClientError.transport("interrupt requires GatewaySession") }
    public func decideApproval(id: String, decision: ApprovalDecision) async throws { throw AgentClientError.transport("approval requires GatewaySession") }
    public func initialDirectory() async throws -> DirectoryListing { throw AgentClientError.transport("files require GatewaySession") }
    public func listFiles(path: String, showHidden: Bool) async throws -> DirectoryListing { throw AgentClientError.transport("files require GatewaySession") }
    public func filePreview(path: String, maxBytes: Int) async throws -> FilePreview { throw AgentClientError.transport("files require GatewaySession") }
    public func createTransfer(_ request: TransferRequest) async throws -> TransferTicket { throw AgentClientError.transport("transfers require explicit REST API") }
    public func uploadChunk(transferId: String, index: Int, data: Data) async throws { throw AgentClientError.transport("transfers require explicit REST API") }
    public func downloadChunk(transferId: String, index: Int) async throws -> Data { throw AgentClientError.transport("transfers require explicit REST API") }
    public func finishTransfer(transferId: String) async throws -> TransferReceipt { throw AgentClientError.transport("transfers require explicit REST API") }
    public func cancelTransfer(transferId: String) async throws { throw AgentClientError.transport("transfers require explicit REST API") }
    public func listAudit(limit: Int) async throws -> [AuditEntry] { throw AgentClientError.transport("audit requires GatewaySession") }
    public func diagnostics() async throws -> Diagnostics { throw AgentClientError.transport("diagnostics mapping pending") }
    public func revokeDevice() async throws { throw AgentClientError.transport("revoke requires GatewaySession") }

    private struct EmptyResponse: Codable, Sendable {}

    private func connect() throws -> (DeviceIdentity, String, CryptoBox, CryptoBox) {
        let (identity, privateKey, deviceId) = try identity()
        let peer: P256.KeyAgreement.PublicKey
        if identity.macPublicKey.count == 65 {
            peer = try P256.KeyAgreement.PublicKey(x963Representation: identity.macPublicKey)
        } else {
            peer = try P256.KeyAgreement.PublicKey(rawRepresentation: identity.macPublicKey)
        }
        let derived = try SessionKeys.derive(
            privateKey: privateKey, peerPublicKey: peer, macId: identity.macId, deviceId: deviceId
        )
        keys = derived
        let phoneBox = CryptoBox(key: derived.phoneToMac, direction: .phoneToMac)
        let macBox = CryptoBox(key: derived.macToPhone, direction: .macToPhone)
        return (identity, deviceId, phoneBox, macBox)
    }

    private func request<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        type: RequestType,
        conversationId: String?,
        payload: Payload,
        response: Response.Type,
        waitForTurnCompletion: Bool = false
    ) async throws -> Response {
        let (identity, deviceId, phoneBox, macBox) = try connect()
        var receiveGuard = ReplayGuard()
        guard let origin = URL(string: identity.origin), var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw AgentClientError.invalidRequest("invalid paired origin")
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/ws"
        var request = URLRequest(url: components.url!)
        request.setValue(deviceId, forHTTPHeaderField: "x-remoteai-device")
        let task = session.webSocketTask(with: request)
        task.resume()
        socket = task
        defer { task.cancel(with: .normalClosure, reason: nil); socket = nil }
        do {
            try await waitUntilConnected(task)
        } catch {
            throw AgentClientError.transport(Self.socketFailureMessage(stage: "connect"))
        }

        let envelope = RequestEnvelope(type: type, conversationId: conversationId, payload: payload)
        let plaintext = try ProtocolCoding.encoder.encode(envelope)
        sendCounter += 1
        let routing = RoutingMetadata(deviceId: deviceId, conversationId: conversationId)
        let sealed = try phoneBox.seal(plaintext, counter: sendCounter, aad: routing.canonicalData())
        let frame = EncryptedFrame(
            counter: sendCounter, routing: routing, ciphertext: sealed.base64EncodedString()
        )
        do {
            try await task.send(.data(try JSONEncoder().encode(frame)))
        } catch {
            throw AgentClientError.transport(Self.socketFailureMessage(stage: "send"))
        }
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw AgentClientError.transport(Self.socketFailureMessage(stage: "receive"))
            }
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: throw AgentClientError.transport("unsupported websocket message")
            }
            let encrypted = try JSONDecoder().decode(EncryptedFrame.self, from: data)
            guard receiveGuard.accept(counter: encrypted.counter),
                let ciphertext = Data(base64Encoded: encrypted.ciphertext)
            else { throw AgentClientError.transport("replayed or malformed frame") }
            let opened = try macBox.open(
                ciphertext, counter: encrypted.counter, aad: encrypted.routing.canonicalData()
            )
            let object = try JSONSerialization.jsonObject(with: opened) as? [String: Any]
            if object?["kind"] as? String == EnvelopeKind.event.rawValue {
                if let event = try? ProtocolCoding.decodeEvent(from: opened) {
                    continuation.yield(event)
                    if waitForTurnCompletion, !Self.shouldKeepSocket(after: event) {
                        return try ProtocolCoding.decoder.decode(Response.self, from: Data("{}".utf8))
                    }
                }
                continue
            }
            let result = try ProtocolCoding.decodeResponse(Response.self, from: opened).payload
            if !waitForTurnCompletion { return result }
        }
    }

    private func waitUntilConnected(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
