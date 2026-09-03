import Foundation

// MARK: - Frozen enumerations

public enum ProviderId: String, Codable, Sendable, Hashable, CaseIterable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

public enum ConversationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case daily
    case project
}

public enum ApprovalDecision: String, Codable, Sendable, Hashable, CaseIterable {
    case allowOnce = "allow_once"
    case deny
}

public enum ConnectionState: String, Sendable, Hashable, CaseIterable {
    case disconnected
    case connecting
    case paired
    case online
    case recovering

    /// Only `online` permits mutating traffic; everything else is read-only cache.
    public var allowsMutation: Bool { self == .online }
}

public enum EnvelopeKind: String, Codable, Sendable, Hashable {
    case request
    case response
    case event
}

// Lenient string enums: an unrecognized wire value decodes to a neutral case
// instead of failing, so an agent-side schema addition never breaks the client.

public enum ConversationStatus: String, Codable, Sendable, Hashable {
    case idle
    case running
    case completed
    case failed
    case interrupted
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConversationStatus(rawValue: raw) ?? .unknown
    }
}

public enum ApprovalCategory: String, Codable, Sendable, Hashable {
    case command
    case fileRead = "file_read"
    case fileWrite = "file_write"
    case network
    case other
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalCategory(rawValue: raw) ?? .unknown
    }
}

public enum ApprovalRisk: String, Codable, Sendable, Hashable {
    case low
    case medium
    case high
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalRisk(rawValue: raw) ?? .unknown
    }
}

public enum FileKind: String, Codable, Sendable, Hashable {
    case file
    case directory
    case symlink
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FileKind(rawValue: raw) ?? .other
    }
}

// MARK: - Errors

public enum ProtocolError: Error, Equatable, Sendable {
    case upgradeRequired(found: Int, supported: Int)
    case malformed(String)
    case agentError(code: String, message: String)
}

// MARK: - Core data structures

public struct ProviderStatus: Codable, Sendable, Hashable, Identifiable {
    public let provider: ProviderId
    public let available: Bool
    public let executablePath: String?
    public let version: String?
    public let reason: String?

    public var id: ProviderId { provider }

    public init(
        provider: ProviderId,
        available: Bool,
        executablePath: String? = nil,
        version: String? = nil,
        reason: String? = nil
    ) {
        self.provider = provider
        self.available = available
        self.executablePath = executablePath
        self.version = version
        self.reason = reason
    }
}

public struct ProviderStatusPayload: Codable, Sendable, Hashable {
    public let providers: [ProviderStatus]

    public init(providers: [ProviderStatus]) {
        self.providers = providers
    }
}

public struct ProjectSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let provider: ProviderId
    public let canonicalPath: String
    public let displayPath: String
    public let title: String
    public let updatedAt: Date
    public let available: Bool

    public init(
        id: String,
        provider: ProviderId,
        canonicalPath: String,
        displayPath: String,
        title: String,
        updatedAt: Date,
        available: Bool
    ) {
        self.id = id
        self.provider = provider
        self.canonicalPath = canonicalPath
        self.displayPath = displayPath
        self.title = title
        self.updatedAt = updatedAt
        self.available = available
    }
}

public struct ConversationSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let provider: ProviderId
    public let kind: ConversationKind
    public let title: String
    public let projectId: String?
    public let projectPath: String?
    public let updatedAt: Date
    public let status: ConversationStatus

    public init(
        id: String,
        provider: ProviderId,
        kind: ConversationKind,
        title: String,
        projectId: String? = nil,
        projectPath: String? = nil,
        updatedAt: Date,
        status: ConversationStatus
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.title = title
        self.projectId = projectId
        self.projectPath = projectPath
        self.updatedAt = updatedAt
        self.status = status
    }
}

public struct CatalogPayload: Codable, Sendable, Hashable {
    public let projects: [ProjectSummary]
    public let conversations: [ConversationSummary]

    public init(projects: [ProjectSummary], conversations: [ConversationSummary]) {
        self.projects = projects
        self.conversations = conversations
    }
}

public struct ApprovalRequest: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let provider: ProviderId
    public let conversationId: String
    public let category: ApprovalCategory
    public let title: String
    public let detail: String
    public let cwd: String?
    public let risk: ApprovalRisk?
    public let createdAt: Date

    public init(
        id: String,
        provider: ProviderId,
        conversationId: String,
        category: ApprovalCategory,
        title: String,
        detail: String,
        cwd: String? = nil,
        risk: ApprovalRisk? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.conversationId = conversationId
        self.category = category
        self.title = title
        self.detail = detail
        self.cwd = cwd
        self.risk = risk
        self.createdAt = createdAt
    }
}

public struct ApprovalResolution: Codable, Sendable, Hashable {
    public let id: String
    public let decision: ApprovalDecision

    public init(id: String, decision: ApprovalDecision) {
        self.id = id
        self.decision = decision
    }
}

public struct FileEntry: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let name: String
    public let kind: FileKind
    public let size: Int64?
    public let modifiedAt: Date?
    public let hidden: Bool
    public let readable: Bool
    public let sensitive: Bool

    public var id: String { path }

    public init(
        path: String,
        name: String,
        kind: FileKind,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        hidden: Bool = false,
        readable: Bool = true,
        sensitive: Bool = false
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.hidden = hidden
        self.readable = readable
        self.sensitive = sensitive
    }
}

// MARK: - Conversation events

public struct ConversationStarted: Codable, Sendable, Hashable {
    public let conversation: ConversationSummary

    public init(conversation: ConversationSummary) {
        self.conversation = conversation
    }
}

public enum MessageRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
    case system
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageRole(rawValue: raw) ?? .unknown
    }
}

public struct MessagePayload: Codable, Sendable, Hashable {
    public let messageId: String
    public let role: MessageRole
    public let text: String

    public init(messageId: String, role: MessageRole, text: String) {
        self.messageId = messageId
        self.role = role
        self.text = text
    }
}

public struct ToolPayload: Codable, Sendable, Hashable {
    public let toolCallId: String
    public let name: String
    public let detail: String?
    public let status: String?

    public init(toolCallId: String, name: String, detail: String? = nil, status: String? = nil) {
        self.toolCallId = toolCallId
        self.name = name
        self.detail = detail
        self.status = status
    }
}

public struct TurnPayload: Codable, Sendable, Hashable {
    public let turnId: String

    public init(turnId: String) {
        self.turnId = turnId
    }
}

public struct TurnFailure: Codable, Sendable, Hashable {
    public let turnId: String
    public let code: String
    public let message: String

    public init(turnId: String, code: String, message: String) {
        self.turnId = turnId
        self.code = code
        self.message = message
    }
}

public enum ConversationEvent: Sendable, Hashable {
    case started(ConversationStarted)
    case userMessage(MessagePayload)
    case delta(MessagePayload)
    case messageCompleted(MessagePayload)
    case toolStarted(ToolPayload)
    case toolUpdated(ToolPayload)
    case toolCompleted(ToolPayload)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(ApprovalResolution)
    case turnCompleted(TurnPayload)
    case turnFailed(TurnFailure)
    case turnInterrupted(TurnPayload)
    case providerStatusChanged(ProviderStatus)
    /// Any type this build does not understand, or a known type whose payload
    /// failed to decode. Safe to ignore; must never break the connection.
    case unsupported(rawType: String)
}

// MARK: - Envelopes

public struct EventEnvelope: Sendable, Hashable, Identifiable {
    public let protocolVersion: Int
    public let messageId: String
    public let sequence: Int
    public let conversationId: String?
    public let rawType: String
    public let event: ConversationEvent

    public var id: String { messageId }

    public init(
        protocolVersion: Int = AppMetadata.protocolVersion,
        messageId: String = UUID().uuidString,
        sequence: Int,
        conversationId: String?,
        rawType: String,
        event: ConversationEvent
    ) {
        self.protocolVersion = protocolVersion
        self.messageId = messageId
        self.sequence = sequence
        self.conversationId = conversationId
        self.rawType = rawType
        self.event = event
    }
}

public struct ResponseEnvelope<Payload: Decodable>: Sendable where Payload: Sendable {
    public let protocolVersion: Int
    public let messageId: String
    public let kind: EnvelopeKind
    public let requestId: String?
    public let sequence: Int
    public let conversationId: String?
    public let type: String
    public let payload: Payload
}

public enum RequestType: String, Codable, Sendable, CaseIterable {
    case providerStatus = "provider.status"
    case conversationsDailyList = "conversations.daily.list"
    case projectsList = "projects.list"
    case projectsConversationsList = "projects.conversations.list"
    case conversationHistory = "conversation.history"
    case conversationStart = "conversation.start"
    case conversationResume = "conversation.resume"
    case conversationSend = "conversation.send"
    case conversationInterrupt = "conversation.interrupt"
    case approvalDecide = "approval.decide"
    case filesList = "files.list"
    case filesMetadata = "files.metadata"
    case filesPreview = "files.preview"
    case transfersCreate = "transfers.create"
    case transfersChunk = "transfers.chunk"
    case transfersFinish = "transfers.finish"
    case transfersCancel = "transfers.cancel"
    case auditList = "audit.list"
    case diagnosticsGet = "diagnostics.get"
    case deviceRevoke = "device.revoke"
}

public struct RequestEnvelope<Payload: Encodable & Sendable>: Encodable, Sendable {
    public let protocolVersion: Int
    public let messageId: String
    public let kind: EnvelopeKind
    public let requestId: String
    public let sequence: Int
    public let conversationId: String?
    public let type: RequestType
    public let payload: Payload

    public init(
        type: RequestType,
        conversationId: String? = nil,
        sequence: Int = 0,
        messageId: String = UUID().uuidString,
        requestId: String = UUID().uuidString,
        payload: Payload
    ) {
        self.protocolVersion = AppMetadata.protocolVersion
        self.messageId = messageId
        self.kind = .request
        self.requestId = requestId
        self.sequence = sequence
        self.conversationId = conversationId
        self.type = type
        self.payload = payload
    }
}

public struct ConversationSendPayload: Codable, Sendable, Hashable {
    public let provider: ProviderId
    public let conversationId: String
    public let text: String

    public init(provider: ProviderId, conversationId: String, text: String) {
        self.provider = provider
        self.conversationId = conversationId
        self.text = text
    }
}

// MARK: - Coding

public enum ProtocolCoding {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "invalid ISO8601 date"
            )
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func object(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProtocolError.malformed("envelope is not a JSON object")
        }
        return object
    }

    private static func checkVersion(_ object: [String: Any]) throws {
        guard let version = object["protocolVersion"] as? Int else {
            throw ProtocolError.malformed("missing protocolVersion")
        }
        guard version == AppMetadata.protocolVersion else {
            throw ProtocolError.upgradeRequired(
                found: version, supported: AppMetadata.protocolVersion
            )
        }
    }

    public static func decodeResponse<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        from data: Data
    ) throws -> ResponseEnvelope<Payload> {
        let object = try object(from: data)
        try checkVersion(object)

        if let error = object["error"] as? [String: Any] {
            throw ProtocolError.agentError(
                code: error["code"] as? String ?? "unknown",
                message: error["message"] as? String ?? ""
            )
        }

        guard let messageId = object["messageId"] as? String,
            let kindRaw = object["kind"] as? String,
            let kind = EnvelopeKind(rawValue: kindRaw),
            let typeName = object["type"] as? String
        else {
            throw ProtocolError.malformed("missing envelope routing fields")
        }

        if typeName == "error" {
            let payload = object["payload"] as? [String: Any]
            let code = payload?["code"] as? String ?? "unknown"
            // Gateway business errors intentionally expose only a stable code;
            // provider stderr, prompts, and credentials never cross this API.
            throw ProtocolError.agentError(code: code, message: "")
        }

        let payloadObject = object["payload"] ?? [String: Any]()
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject)
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: payloadData)
        } catch {
            throw ProtocolError.malformed("payload for \(typeName): \(error)")
        }

        return ResponseEnvelope(
            protocolVersion: AppMetadata.protocolVersion,
            messageId: messageId,
            kind: kind,
            requestId: object["requestId"] as? String,
            sequence: object["sequence"] as? Int ?? 0,
            conversationId: object["conversationId"] as? String,
            type: typeName,
            payload: payload
        )
    }

    public static func decodeEvent(from data: Data) throws -> EventEnvelope {
        let object = try object(from: data)
        try checkVersion(object)

        guard let messageId = object["messageId"] as? String,
            let rawType = object["type"] as? String
        else {
            throw ProtocolError.malformed("missing envelope routing fields")
        }

        let sequence = object["sequence"] as? Int ?? 0
        let conversationId = object["conversationId"] as? String
        let payloadObject = object["payload"] ?? [String: Any]()
        let payloadData = (try? JSONSerialization.data(withJSONObject: payloadObject)) ?? Data("{}".utf8)

        return EventEnvelope(
            messageId: messageId,
            sequence: sequence,
            conversationId: conversationId,
            rawType: rawType,
            event: decodeEventPayload(rawType: rawType, payload: payloadData)
        )
    }

    /// Maps a wire event type onto a typed case. Unknown types and undecodable
    /// payloads both degrade to `.unsupported` so a schema change can never
    /// break the connection.
    static func decodeEventPayload(rawType: String, payload: Data) -> ConversationEvent {
        func decode<T: Decodable>(_ type: T.Type) -> T? {
            try? decoder.decode(T.self, from: payload)
        }

        switch rawType {
        case "conversation.started":
            return decode(ConversationStarted.self).map(ConversationEvent.started)
                ?? .unsupported(rawType: rawType)
        case "conversation.user_message":
            return decode(MessagePayload.self).map(ConversationEvent.userMessage)
                ?? .unsupported(rawType: rawType)
        case "conversation.delta":
            return decode(MessagePayload.self).map(ConversationEvent.delta)
                ?? .unsupported(rawType: rawType)
        case "conversation.message_completed":
            return decode(MessagePayload.self).map(ConversationEvent.messageCompleted)
                ?? .unsupported(rawType: rawType)
        case "tool.started":
            return decode(ToolPayload.self).map(ConversationEvent.toolStarted)
                ?? .unsupported(rawType: rawType)
        case "tool.updated":
            return decode(ToolPayload.self).map(ConversationEvent.toolUpdated)
                ?? .unsupported(rawType: rawType)
        case "tool.completed":
            return decode(ToolPayload.self).map(ConversationEvent.toolCompleted)
                ?? .unsupported(rawType: rawType)
        case "approval.requested":
            return decode(ApprovalRequest.self).map(ConversationEvent.approvalRequested)
                ?? .unsupported(rawType: rawType)
        case "approval.resolved":
            return decode(ApprovalResolution.self).map(ConversationEvent.approvalResolved)
                ?? .unsupported(rawType: rawType)
        case "turn.completed":
            return decode(TurnPayload.self).map(ConversationEvent.turnCompleted)
                ?? .unsupported(rawType: rawType)
        case "turn.failed":
            return decode(TurnFailure.self).map(ConversationEvent.turnFailed)
                ?? .unsupported(rawType: rawType)
        case "turn.interrupted":
            return decode(TurnPayload.self).map(ConversationEvent.turnInterrupted)
                ?? .unsupported(rawType: rawType)
        case "provider.status_changed":
            return decode(ProviderStatus.self).map(ConversationEvent.providerStatusChanged)
                ?? .unsupported(rawType: rawType)
        default:
            return .unsupported(rawType: rawType)
        }
    }
}
