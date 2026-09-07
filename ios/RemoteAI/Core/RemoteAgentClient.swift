import CryptoKit
import Foundation

/// Minimal URLSession transport for a paired Agent. REST is used for the
/// read-only catalog/diagnostics APIs; mutating conversation requests travel
/// over the encrypted websocket required by GatewaySession.
public actor RemoteAgentClient: AgentClient {
    private nonisolated let fanout = EventFanout()

    /// A fresh delivery of the feed per caller: two open transcripts must both
    /// see every event.
    public nonisolated var events: AsyncStream<EventEnvelope> { fanout.stream() }

    private let store: SecretStore
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var keys: SessionKeys?
    private var sendCounter: UInt64 = 0
    private var fileRoot: String?
    private var uploadTransfers: [String: UploadTransferContext] = [:]
    private var downloadTransfers: [String: DownloadTransferContext] = [:]

    private static let transferChunkSize = 1_048_576

    private struct HTTPFailure: Error {
        let statusCode: Int
        let body: Data
    }

    private struct UploadTransferContext: Sendable {
        let destination: String
        let expectedSha256: String
        let chunkSize: Int
    }

    private struct DownloadTransferContext: Sendable {
        let path: String
        let byteCount: Int64
        let chunkSize: Int
        let totalChunks: Int
    }

    private struct TransferCreatePayload: Encodable {
        let path: String
        let expectedSha256: String?
        let conflictPolicy: ConflictPolicy?
    }

    private struct TransferCreateResponse: Decodable {
        let id: String
        let destination: String
    }

    private struct TransferConflictResponse: Decodable {
        let error: String
        let existingPath: String
        let existingSize: Int64?
    }

    private struct TransferChunkPayload: Encodable {
        let offset: Int64
        let data: String
    }

    public init(store: SecretStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public static func endpoint(origin: URL, path: String) throws -> URL {
        guard ["http", "https"].contains(origin.scheme?.lowercased()), origin.host != nil,
            origin.user == nil, origin.password == nil
        else { throw AgentClientError.invalidRequest("invalid agent origin") }
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw AgentClientError.invalidRequest("invalid agent origin")
        }
        let base = components.percentEncodedPath.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [base, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        guard let endpoint = components.url else {
            throw AgentClientError.invalidRequest("invalid agent path")
        }
        return endpoint
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
        case "timeout": return "The Mac did not finish the turn in time."
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

    private func restData(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        let (origin, _, deviceId) = try originAndIdentity()
        var components = URLComponents(url: try Self.endpoint(origin: origin, path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(deviceId, forHTTPHeaderField: "x-remoteai-device")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentClientError.transport("invalid response") }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPFailure(statusCode: http.statusCode, body: data)
        }
        return data
    }

    private func rest<T: Decodable>(_ method: String, path: String, query: [URLQueryItem] = []) async throws -> T {
        let data: Data
        do {
            data = try await restData(method, path: path, query: query)
        } catch let failure as HTTPFailure {
            throw Self.genericHTTPError(failure.statusCode)
        }
        do { return try ProtocolCoding.decoder.decode(T.self, from: data) }
        catch { throw AgentClientError.transport("decode_failed") }
    }

    private static func genericHTTPError(_ statusCode: Int) -> AgentClientError {
        switch statusCode {
        case 401: return .notPaired
        case 404: return .notFound("remote_resource")
        case 409: return .rejected("conflict")
        case 503: return .transport("service_unavailable")
        default: return .transport("http_\(statusCode)")
        }
    }

    private static func fileHTTPError(_ statusCode: Int) -> AgentClientError {
        switch statusCode {
        case 401: return .notPaired
        case 403: return .rejected("path_outside_root")
        case 404: return .notFound("file")
        case 503: return .transport("files_unavailable")
        default: return .transport("files_http_\(statusCode)")
        }
    }

    private static func transferHTTPError(_ statusCode: Int) -> AgentClientError {
        switch statusCode {
        case 401: return .notPaired
        case 403: return .rejected("path_outside_root")
        case 404: return .notFound("transfer")
        case 409: return .rejected("conflict")
        case 413: return .invalidRequest("chunk_too_large")
        case 503: return .transport("transfers_unavailable")
        default: return .transport("transfers_http_\(statusCode)")
        }
    }

    private static func validateFilePath(_ path: String) throws {
        guard path == "." || path.hasPrefix("/") else {
            throw AgentClientError.invalidRequest("file_path_must_be_absolute")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) || path == "." else {
            throw AgentClientError.rejected("path_traversal")
        }
    }

    private static func transferDestination(for request: TransferRequest) throws -> String {
        try validateFilePath(request.remoteDirectory)
        guard request.byteCount >= 0,
              !request.name.isEmpty,
              request.name != ".",
              request.name != "..",
              !request.name.contains("/"),
              !request.name.contains("\0")
        else {
            throw AgentClientError.invalidRequest("invalid_transfer")
        }
        let directory = request.remoteDirectory == "/"
            ? "" : request.remoteDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + [directory, request.name].filter { !$0.isEmpty }.joined(separator: "/")
    }

    private static func totalChunks(byteCount: Int64, chunkSize: Int) throws -> Int {
        guard byteCount >= 0, chunkSize > 0 else {
            throw AgentClientError.invalidRequest("invalid_transfer_size")
        }
        if byteCount == 0 { return 1 }
        let count = ((byteCount - 1) / Int64(chunkSize)) + 1
        guard let result = Int(exactly: count) else {
            throw AgentClientError.invalidRequest("transfer_too_large")
        }
        return result
    }

    private static func parentPath(of path: String, boundedBy root: String?) -> String? {
        if path == root { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return nil }
        if let root {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard parent == root || parent.hasPrefix(prefix) else { return nil }
        }
        return parent
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try ProtocolCoding.decoder.decode(type, from: data) }
        catch { throw AgentClientError.transport("decode_failed") }
    }

    public func providerStatus() async throws -> [ProviderStatus] {
        struct Health: Decodable { let status: ProviderStatus }
        struct Report: Decodable { let providers: [Health] }
        let report: Report = try await rest("GET", path: "v1/diagnostics")
        return report.providers.map(\.status)
    }

    public func listDailyConversations(provider: ProviderId) async throws -> [ConversationSummary] {
        let conversations: [ConversationSummary] = try await rest(
            "GET",
            path: "v1/conversations/daily",
            query: [.init(name: "provider", value: provider.rawValue)]
        )
        guard conversations.allSatisfy({ $0.provider == provider && $0.kind == .daily }) else {
            throw AgentClientError.providerMismatch
        }
        return conversations
    }

    public func listProjects(provider: ProviderId) async throws -> [ProjectSummary] {
        let projects: [ProjectSummary] = try await rest(
            "GET",
            path: "v1/projects",
            query: [.init(name: "provider", value: provider.rawValue)]
        )
        guard projects.allSatisfy({ $0.provider == provider }) else {
            throw AgentClientError.providerMismatch
        }
        return projects
    }

    public func listProjectConversations(provider: ProviderId, projectId: String) async throws -> [ConversationSummary] {
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.remove(charactersIn: "/%")
        guard let encodedProjectId = projectId.addingPercentEncoding(withAllowedCharacters: pathAllowed)
        else { throw AgentClientError.invalidRequest("invalid project id") }
        let conversations: [ConversationSummary] = try await rest(
            "GET",
            path: "v1/projects/\(encodedProjectId)/conversations",
            query: [.init(name: "provider", value: provider.rawValue)]
        )
        guard conversations.allSatisfy({
            $0.provider == provider && $0.kind == .project && $0.projectId == projectId
        }) else { throw AgentClientError.providerMismatch }
        return conversations
    }

    private struct HistoryRequestPayload: Codable, Sendable {
        let provider: ProviderId
        let conversationId: String
        let cursor: String?
        let limit: Int
    }

    private struct HistoryResponse: Decodable, Sendable {
        let conversationId: String
        let events: [HistoryWireEvent]
        let nextCursor: String?
    }

    private struct HistoryWireEvent: Decodable, Sendable {
        let messageId: String?
        let sequence: Int?
        let conversationId: String?
        let rawType: String
        let event: ConversationEvent
        let fingerprint: String

        private enum CodingKeys: String, CodingKey {
            case messageId, sequence, conversationId, type, payload
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
            sequence = try container.decodeIfPresent(Int.self, forKey: .sequence)
            conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
            rawType = try container.decode(String.self, forKey: .type)
            let payload = try container.decode(JSONValue.self, forKey: .payload)
            let payloadData = try payload.data()
            event = ProtocolCoding.decodeEventPayload(rawType: rawType, payload: payloadData)
            var fingerprintData = Data(rawType.utf8)
            fingerprintData.append(0)
            fingerprintData.append(payloadData)
            fingerprint = SHA256.hash(data: fingerprintData).map { String(format: "%02x", $0) }.joined()
        }
    }

    public static func decodeHistoryPage(
        _ data: Data,
        provider: ProviderId,
        conversationId: String
    ) throws -> HistoryPage {
        let response = try ProtocolCoding.decoder.decode(HistoryResponse.self, from: data)
        return try historyPage(
            from: response,
            provider: provider,
            requestedConversationId: conversationId
        )
    }

    private static func historyPage(
        from response: HistoryResponse,
        provider: ProviderId,
        requestedConversationId: String
    ) throws -> HistoryPage {
        guard response.conversationId == requestedConversationId else {
            throw AgentClientError.providerMismatch
        }
        let events = response.events.enumerated().map { index, wire in
            EventEnvelope(
                messageId: wire.messageId
                    ?? "history-\(provider.rawValue)-\(requestedConversationId)-\(wire.fingerprint)",
                sequence: wire.sequence ?? index + 1,
                conversationId: wire.conversationId ?? requestedConversationId,
                rawType: wire.rawType,
                event: wire.event
            )
        }
        return HistoryPage(
            events: events,
            hasMore: response.nextCursor != nil,
            nextCursor: response.nextCursor
        )
    }

    public func history(
        provider: ProviderId,
        conversationId: String,
        cursor: String?,
        limit: Int
    ) async throws -> HistoryPage {
        let response: HistoryResponse = try await request(
            type: .conversationHistory,
            conversationId: conversationId,
            payload: HistoryRequestPayload(
                provider: provider,
                conversationId: conversationId,
                cursor: cursor,
                limit: limit
            ),
            response: HistoryResponse.self
        )
        return try Self.historyPage(
            from: response,
            provider: provider,
            requestedConversationId: conversationId
        )
    }

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
    public func initialDirectory() async throws -> DirectoryListing {
        do {
            let metadataData = try await restData(
                "GET", path: "v1/files/metadata",
                query: [.init(name: "path", value: ".")]
            )
            let root = try decode(FileEntry.self, from: metadataData)
            guard root.kind == .directory, root.path.hasPrefix("/") else {
                throw AgentClientError.transport("invalid_file_root")
            }
            fileRoot = root.path
            return try await listFiles(path: root.path, showHidden: false)
        } catch let failure as HTTPFailure {
            throw Self.fileHTTPError(failure.statusCode)
        }
    }

    public func listFiles(path: String, showHidden: Bool) async throws -> DirectoryListing {
        try Self.validateFilePath(path)
        do {
            let data = try await restData(
                "GET", path: "v1/files/list",
                query: [
                    .init(name: "path", value: path),
                    .init(name: "includeSensitive", value: showHidden ? "true" : "false"),
                ]
            )
            let entries = try decode([FileEntry].self, from: data).sorted { left, right in
                if left.kind == .directory, right.kind != .directory { return true }
                if left.kind != .directory, right.kind == .directory { return false }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
            return DirectoryListing(
                path: path,
                parentPath: Self.parentPath(of: path, boundedBy: fileRoot),
                entries: entries
            )
        } catch let failure as HTTPFailure {
            throw Self.fileHTTPError(failure.statusCode)
        }
    }

    public func filePreview(path: String, maxBytes: Int) async throws -> FilePreview {
        try Self.validateFilePath(path)
        let boundedBytes = max(0, min(maxBytes, 1_048_576))
        do {
            let metadataData = try await restData(
                "GET", path: "v1/files/metadata",
                query: [.init(name: "path", value: path)]
            )
            let entry = try decode(FileEntry.self, from: metadataData)
            guard entry.kind == .file else {
                throw AgentClientError.invalidRequest("preview_requires_file")
            }
            let bytes = try await restData(
                "GET", path: "v1/files/preview",
                query: [
                    .init(name: "path", value: path),
                    .init(name: "maxBytes", value: String(boundedBytes)),
                ]
            )
            let sourceSize = entry.size.flatMap(Int.init(exactly:)) ?? bytes.count
            return FilePreview(
                path: entry.path,
                text: String(data: bytes, encoding: .utf8),
                byteCount: sourceSize,
                truncated: sourceSize > bytes.count
            )
        } catch let failure as HTTPFailure {
            throw Self.fileHTTPError(failure.statusCode)
        }
    }
    public func createTransfer(_ request: TransferRequest) async throws -> TransferTicket {
        let destination = try Self.transferDestination(for: request)
        let chunkSize = Self.transferChunkSize
        let totalChunks = try Self.totalChunks(
            byteCount: request.byteCount, chunkSize: chunkSize
        )
        if request.direction == .download {
            let id = "download-\(UUID().uuidString)"
            downloadTransfers[id] = DownloadTransferContext(
                path: destination,
                byteCount: request.byteCount,
                chunkSize: chunkSize,
                totalChunks: totalChunks
            )
            return TransferTicket(
                id: id,
                destinationPath: destination,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                conflict: nil
            )
        }
        let payload = TransferCreatePayload(
            path: destination,
            expectedSha256: request.expectedSha256,
            conflictPolicy: request.conflictPolicy
        )
        let body: Data
        do {
            body = try JSONEncoder().encode(payload)
        } catch {
            throw AgentClientError.invalidRequest("transfer_encode_failed")
        }

        do {
            let data = try await restData(
                "POST", path: "v1/transfers/create", body: body,
                contentType: "application/json"
            )
            let created = try decode(TransferCreateResponse.self, from: data)
            let digest = request.expectedSha256 ?? ""
            uploadTransfers[created.id] = UploadTransferContext(
                destination: created.destination,
                expectedSha256: digest,
                chunkSize: chunkSize
            )
            return TransferTicket(
                id: created.id,
                destinationPath: created.destination,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                conflict: nil
            )
        } catch let failure as HTTPFailure where failure.statusCode == 409 {
            let conflict = try decode(TransferConflictResponse.self, from: failure.body)
            guard conflict.error == "conflict" else {
                throw AgentClientError.transport("invalid_conflict_response")
            }
            return TransferTicket(
                id: "conflict-\(UUID().uuidString)",
                destinationPath: destination,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                conflict: TransferConflict(
                    existingPath: conflict.existingPath,
                    existingSize: conflict.existingSize
                )
            )
        } catch let failure as HTTPFailure {
            throw Self.transferHTTPError(failure.statusCode)
        }
    }

    public func uploadChunk(transferId: String, index: Int, data: Data) async throws {
        guard let transfer = uploadTransfers[transferId] else {
            throw AgentClientError.notFound("transfer")
        }
        guard index >= 0, data.count <= transfer.chunkSize else {
            throw AgentClientError.invalidRequest("invalid_chunk")
        }
        let (offset, overflow) = Int64(index).multipliedReportingOverflow(
            by: Int64(transfer.chunkSize)
        )
        guard !overflow else { throw AgentClientError.invalidRequest("invalid_chunk") }
        let payload = TransferChunkPayload(
            offset: offset,
            data: data.base64EncodedString()
        )
        let body = try JSONEncoder().encode(payload)
        do {
            _ = try await restData(
                "POST", path: "v1/transfers/\(transferId)/chunk", body: body,
                contentType: "application/json"
            )
        } catch let failure as HTTPFailure {
            throw Self.transferHTTPError(failure.statusCode)
        }
    }
    public func downloadChunk(transferId: String, index: Int) async throws -> Data {
        guard let transfer = downloadTransfers[transferId] else {
            throw AgentClientError.notFound("transfer")
        }
        guard index >= 0, index < transfer.totalChunks else {
            throw AgentClientError.invalidRequest("invalid_chunk")
        }
        let (start, overflow) = Int64(index).multipliedReportingOverflow(
            by: Int64(transfer.chunkSize)
        )
        guard !overflow else { throw AgentClientError.invalidRequest("invalid_chunk") }
        let (candidateEnd, endOverflow) = start.addingReportingOverflow(
            Int64(transfer.chunkSize)
        )
        let end = endOverflow ? transfer.byteCount : min(transfer.byteCount, candidateEnd)
        do {
            let data = try await restData(
                "GET", path: "v1/transfers/download",
                query: [
                    .init(name: "path", value: transfer.path),
                    .init(name: "start", value: String(start)),
                    .init(name: "end", value: String(end)),
                ]
            )
            if index == transfer.totalChunks - 1 {
                downloadTransfers.removeValue(forKey: transferId)
            }
            return data
        } catch let failure as HTTPFailure {
            throw Self.transferHTTPError(failure.statusCode)
        }
    }
    public func finishTransfer(transferId: String) async throws -> TransferReceipt {
        guard let transfer = uploadTransfers[transferId] else {
            throw AgentClientError.notFound("transfer")
        }
        do {
            _ = try await restData("POST", path: "v1/transfers/\(transferId)/finish")
        } catch let failure as HTTPFailure {
            throw Self.transferHTTPError(failure.statusCode)
        }
        uploadTransfers.removeValue(forKey: transferId)
        return TransferReceipt(
            id: transferId,
            finalPath: transfer.destination,
            sha256: transfer.expectedSha256
        )
    }

    public func cancelTransfer(transferId: String) async throws {
        if downloadTransfers.removeValue(forKey: transferId) != nil {
            return
        }
        guard uploadTransfers[transferId] != nil else {
            throw AgentClientError.notFound("transfer")
        }
        do {
            _ = try await restData("POST", path: "v1/transfers/\(transferId)/cancel")
        } catch let failure as HTTPFailure {
            throw Self.transferHTTPError(failure.statusCode)
        }
        uploadTransfers.removeValue(forKey: transferId)
    }
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

    // MARK: - Accounts

    private struct AccountRequest: Encodable, Sendable {
        let provider: ProviderId
        var label: String?
        var sessionId: String?
        var text: String?
    }

    private struct LoginStatusResponse: Decodable, Sendable {
        let progress: LoginProgress?
    }

    public func accounts(provider: ProviderId) async throws -> AccountsView {
        try await accountRequest(.providerAccounts, AccountRequest(provider: provider))
    }

    public func saveAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        try await accountRequest(
            .providerAccountSave, AccountRequest(provider: provider, label: label)
        )
    }

    public func deleteAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        try await accountRequest(
            .providerAccountDelete, AccountRequest(provider: provider, label: label)
        )
    }

    public func activateAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        try await accountRequest(
            .providerAccountActivate, AccountRequest(provider: provider, label: label)
        )
    }

    public func logout(provider: ProviderId) async throws -> AccountsView {
        try await accountRequest(.providerLogout, AccountRequest(provider: provider))
    }

    public func startLogin(provider: ProviderId, label: String?) async throws -> LoginProgress {
        try await request(
            type: .providerLoginStart,
            conversationId: nil,
            payload: AccountRequest(provider: provider, label: label),
            response: LoginProgress.self
        )
    }

    public func loginProgress(provider: ProviderId) async throws -> LoginProgress? {
        try await request(
            type: .providerLoginStatus,
            conversationId: nil,
            payload: AccountRequest(provider: provider),
            response: LoginStatusResponse.self
        )
        .progress
    }

    public func sendLoginInput(
        provider: ProviderId, sessionId: String, text: String
    ) async throws {
        _ = try await request(
            type: .providerLoginInput,
            conversationId: nil,
            payload: AccountRequest(provider: provider, sessionId: sessionId, text: text),
            response: EmptyResponse.self
        )
    }

    public func cancelLogin(provider: ProviderId, sessionId: String) async throws {
        _ = try await request(
            type: .providerLoginCancel,
            conversationId: nil,
            payload: AccountRequest(provider: provider, sessionId: sessionId),
            response: EmptyResponse.self
        )
    }

    private func accountRequest(
        _ type: RequestType, _ payload: AccountRequest
    ) async throws -> AccountsView {
        let view: AccountsView = try await request(
            type: type, conversationId: nil, payload: payload, response: AccountsView.self
        )
        guard view.provider == payload.provider else { throw AgentClientError.providerMismatch }
        return view
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
                message = try await receiveMessage(
                    task, timeoutNanoseconds: waitForTurnCompletion ? 30_000_000_000 : 15_000_000_000
                )
            } catch let error as AgentClientError {
                throw error
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
                    fanout.yield(event)
                    if waitForTurnCompletion, !Self.shouldKeepSocket(after: event) {
                        return try ProtocolCoding.decoder.decode(Response.self, from: Data("{}".utf8))
                    }
                }
                continue
            }
            let result: Response
            do {
                result = try ProtocolCoding.decodeResponse(Response.self, from: opened).payload
            } catch let ProtocolError.agentError(code, _) {
                throw AgentClientError.rejected(code)
            }
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

    private func receiveMessage(
        _ task: URLSessionWebSocketTask, timeoutNanoseconds: UInt64
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw AgentClientError.transport(Self.socketFailureMessage(stage: "timeout"))
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AgentClientError.transport(Self.socketFailureMessage(stage: "receive"))
            }
            return result
        }
    }
}

private enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON payload"
            )
        }
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private var object: Any {
        switch self {
        case let .object(value): return value.mapValues(\.object)
        case let .array(value): return value.map(\.object)
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case .null: return NSNull()
        }
    }
}
