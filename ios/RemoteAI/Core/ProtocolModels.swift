import Foundation

// MARK: - Frozen enumerations

public enum ProviderId: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case codex
    case claude

    public var id: String { rawValue }

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

public enum ConversationWriteState: String, Codable, Sendable, Hashable {
    case available
    case busy
    case unavailable
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConversationWriteState(rawValue: raw) ?? .unknown
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

/// Whether a provider's CLI is signed in.
///
/// `unknown` is not a synonym for `loggedOut`: the Mac reports it when the CLI
/// could not be asked, and telling someone their login expired on that basis
/// sends them to re-authenticate for nothing.
public enum LoginState: String, Codable, Sendable, Hashable {
    case loggedIn = "logged_in"
    case loggedOut = "logged_out"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LoginState(rawValue: raw) ?? .unknown
    }
}

public struct ProviderLogin: Codable, Sendable, Hashable {
    public let state: LoginState
    /// How the person would recognise this account — an email, or the sign-in
    /// method where there is no email.
    public let account: String?
    /// Organisation and plan, when the provider reports them.
    public let detail: String?

    public init(state: LoginState, account: String? = nil, detail: String? = nil) {
        self.state = state
        self.account = account
        self.detail = detail
    }
}

/// Why a provider will keep refusing until something is done about it.
public enum ProviderProblemCode: String, Codable, Sendable, Hashable {
    case quotaExhausted = "quota_exhausted"
    case rateLimited = "rate_limited"
    case loginExpired = "login_expired"
    case modelUnavailable = "model_unavailable"
    /// A code this build does not know. Shown with the Mac's own message
    /// rather than swallowed.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProviderProblemCode(rawValue: raw) ?? .unknown
    }
}

public struct ProviderProblem: Codable, Sendable, Hashable {
    public let code: ProviderProblemCode
    /// The provider's own words. Usually carries what the person needs — a
    /// link, or the hour a limit resets — so it is shown verbatim.
    public let message: String
    public let observedAt: Date?

    public init(code: ProviderProblemCode, message: String, observedAt: Date? = nil) {
        self.code = code
        self.message = message
        self.observedAt = observedAt
    }

    /// A one-line reason, naming the provider, for the top of the screen.
    ///
    /// The message alone is the provider's, written for a terminal; it says
    /// what happened but not which of the two providers it happened to.
    public func headline(for provider: ProviderId) -> String {
        let name = provider.displayName
        switch code {
        case .quotaExhausted: return "\(name) has run out of credit"
        case .rateLimited: return "\(name) is rate limited"
        case .loginExpired: return "\(name) needs to be signed in again"
        case .modelUnavailable: return "\(name) cannot use this model"
        case .unknown: return "\(name) reported a problem"
        }
    }

    /// Whether signing in again is what would fix this.
    public var needsLogin: Bool { code == .loginExpired }
}

public struct ProviderStatus: Codable, Sendable, Hashable, Identifiable {
    public let provider: ProviderId
    public let available: Bool
    public let executablePath: String?
    public let version: String?
    public let reason: String?
    /// Which account the CLI is signed in as. `nil` when the Mac has not
    /// been able to ask — an unavailable CLI is never reported as logged out.
    public let login: ProviderLogin?
    /// Why this provider is refusing, if it is.
    public let problem: ProviderProblem?

    public var id: ProviderId { provider }

    public init(
        provider: ProviderId,
        available: Bool,
        executablePath: String? = nil,
        version: String? = nil,
        reason: String? = nil,
        login: ProviderLogin? = nil,
        problem: ProviderProblem? = nil
    ) {
        self.provider = provider
        self.available = available
        self.executablePath = executablePath
        self.version = version
        self.reason = reason
        self.login = login
        self.problem = problem
    }
}

/// One account the Mac has a saved credential for.
public struct AccountEntry: Codable, Sendable, Hashable, Identifiable {
    /// The name the person gave it. Unique per provider, and the handle every
    /// account request uses.
    public let label: String
    /// What the CLI called the account when it was saved — an email, usually.
    public let display: String?
    /// Whether this is the account the CLI is using now.
    public let isCurrent: Bool
    /// Whether the credential is still in the Mac's keychain. An entry can
    /// outlive its secret, and offering to switch to one that is gone would
    /// only fail.
    public let hasCredential: Bool

    public var id: String { label }

    public init(
        label: String, display: String? = nil, isCurrent: Bool = false,
        hasCredential: Bool = true
    ) {
        self.label = label
        self.display = display
        self.isCurrent = isCurrent
        self.hasCredential = hasCredential
    }
}

/// Everything the accounts screen shows for one provider.
public struct AccountsView: Codable, Sendable, Hashable {
    public let provider: ProviderId
    public let accounts: [AccountEntry]
    public let login: ProviderLogin
    /// Whether a sign-in is running on the Mac right now — possibly one this
    /// phone did not start.
    public let loginInProgress: Bool
    /// Why the last sign-in did not take, if one did not. Comes from the view
    /// rather than only from an event, because this phone's socket lives for
    /// one request and may not have been connected when it ended.
    public let lastLoginMessage: String?

    public init(
        provider: ProviderId, accounts: [AccountEntry], login: ProviderLogin,
        loginInProgress: Bool = false, lastLoginMessage: String? = nil
    ) {
        self.provider = provider
        self.accounts = accounts
        self.login = login
        self.loginInProgress = loginInProgress
        self.lastLoginMessage = lastLoginMessage
    }
}

/// A sign-in flow in progress on the Mac, as the phone sees it.
public struct LoginProgress: Codable, Sendable, Hashable {
    public let sessionId: String
    public let provider: ProviderId
    /// Everything the CLI has printed, terminal codes already removed. Shown
    /// verbatim: it is the only account of what the flow is doing.
    public let output: String
    /// The link to open, once the CLI has printed one.
    public let verificationUrl: String?
    /// The code to enter at that link. Codex shows one; Claude asks for one.
    public let userCode: String?
    /// Whether the CLI is waiting for something to be typed.
    public let awaitingInput: Bool

    public init(
        sessionId: String, provider: ProviderId, output: String = "",
        verificationUrl: String? = nil, userCode: String? = nil, awaitingInput: Bool = false
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.output = output
        self.verificationUrl = verificationUrl
        self.userCode = userCode
        self.awaitingInput = awaitingInput
    }
}

/// How a sign-in ended.
public struct LoginOutcome: Codable, Sendable, Hashable {
    public let sessionId: String
    public let provider: ProviderId
    public let succeeded: Bool
    /// Why it did not, in the CLI's own words.
    public let message: String?

    public init(
        sessionId: String, provider: ProviderId, succeeded: Bool, message: String? = nil
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.succeeded = succeeded
        self.message = message
    }
}

/// What the phone needs to stream audio to the speech service itself.
///
/// The account key that mints these stays on the Mac. This token expires, so
/// what the phone holds is worth little for long, and the audio goes straight
/// from the phone to the service — never through the Mac.
public struct SpeechCredentials: Codable, Sendable, Hashable {
    /// Identifies the speech project.
    public let appkey: String
    public let token: String
    public let expiresAt: Date
    /// Where to stream. Region-scoped with the token, so not the phone's to
    /// choose.
    public let endpoint: String

    public init(appkey: String, token: String, expiresAt: Date, endpoint: String) {
        self.appkey = appkey
        self.token = token
        self.expiresAt = expiresAt
        self.endpoint = endpoint
    }

    /// Whether this is still worth using. A token with a moment left would
    /// expire mid-sentence.
    public func isUsable(at moment: Date = Date(), margin: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(moment) > margin
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

/// Which of a provider's front ends recorded a conversation.
///
/// The phone lists everything on the Mac; the desktop app lists only its own.
/// Naming the difference is what stops a project full of terminal sessions
/// reading as phantom data.
public enum ConversationSource: String, Codable, Sendable, Hashable {
    case desktop
    case terminal
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConversationSource(rawValue: raw) ?? .unknown
    }

    /// Short enough for a list row. `nil` where the provider has one front end
    /// and the distinction would be noise.
    public var label: String? {
        switch self {
        case .desktop: return "Desktop"
        case .terminal: return "Terminal"
        case .unknown: return nil
        }
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
    public let writeState: ConversationWriteState?
    public let writeBlockCode: String?
    public let source: ConversationSource?
    /// Where the conversation actually ran, when that is not the project's own
    /// directory — a git worktree belongs to the project above it, but the
    /// reader should still be able to tell.
    public let workingPath: String?

    public init(
        id: String,
        provider: ProviderId,
        kind: ConversationKind,
        title: String,
        projectId: String? = nil,
        projectPath: String? = nil,
        updatedAt: Date,
        status: ConversationStatus,
        writeState: ConversationWriteState? = nil,
        writeBlockCode: String? = nil,
        source: ConversationSource? = nil,
        workingPath: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.title = title
        self.projectId = projectId
        self.projectPath = projectPath
        self.source = source
        self.workingPath = workingPath
        self.updatedAt = updatedAt
        self.status = status
        self.writeState = writeState
        self.writeBlockCode = writeBlockCode
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

/// `conversation.started` arrives in two shapes: the mock agent sends a full
/// summary, while the Rust agent sends the provider-native session facts it
/// learns from the CLI's `system/init`. Both must decode.
public struct ConversationStarted: Codable, Sendable, Hashable {
    public let conversation: ConversationSummary?
    public let provider: ProviderId?
    public let sessionId: String?
    public let cwd: String?
    public let model: String?

    public init(
        conversation: ConversationSummary? = nil,
        provider: ProviderId? = nil,
        sessionId: String? = nil,
        cwd: String? = nil,
        model: String? = nil
    ) {
        self.conversation = conversation
        self.provider = provider ?? conversation?.provider
        self.sessionId = sessionId ?? conversation?.id
        self.cwd = cwd ?? conversation?.projectPath
        self.model = model
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

/// A streamed fragment or a whole message.
///
/// The Rust agent's `conversation.delta` carries only `{"text": …}` — the CLI
/// does not label each fragment — so `messageId` and `role` must be optional
/// or every delta decodes to `.unsupported` and the reply is silently dropped.
public struct MessagePayload: Codable, Sendable, Hashable {
    public let messageId: String?
    public let role: MessageRole
    public let text: String

    public init(messageId: String? = nil, role: MessageRole = .assistant, text: String) {
        self.messageId = messageId
        self.role = role
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        role = try container.decodeIfPresent(MessageRole.self, forKey: .role) ?? .assistant
        // `text` stays required: a payload without it carries no message at
        // all and must degrade to .unsupported rather than render an empty
        // bubble.
        text = try container.decode(String.self, forKey: .text)
    }
}

public struct ReasoningPayload: Codable, Sendable, Hashable {
    public let reasoningId: String
    public let text: String

    public init(reasoningId: String, text: String) {
        self.reasoningId = reasoningId
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

    private enum CodingKeys: String, CodingKey {
        case toolCallId
        case toolId
        case id
        case name
        case detail
        case text
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
            ?? container.decodeIfPresent(String.self, forKey: .toolId)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        {
            self.toolCallId = toolCallId
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.toolCallId,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "missing tool identifier"
                )
            )
        }
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Tool"
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
            ?? container.decodeIfPresent(String.self, forKey: .text)
        status = try container.decodeIfPresent(String.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(status, forKey: .status)
    }
}

/// The Rust agent forwards the CLI's own result object here, which has no
/// `turnId`, so the field is optional rather than required.
public struct TurnPayload: Codable, Sendable, Hashable {
    public let turnId: String?

    public init(turnId: String? = nil) {
        self.turnId = turnId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
    }
}

public struct TurnFailure: Codable, Sendable, Hashable {
    public let turnId: String?
    public let code: String
    public let message: String

    public init(turnId: String? = nil, code: String, message: String) {
        self.turnId = turnId
        self.code = code
        self.message = message
    }

    private enum Keys: String, CodingKey {
        case turnId, code, message
        // The CLI result object's own field names.
        case result
        case apiErrorStatus = "api_error_status"
        case subtype
    }

    /// Accepts either the client-shaped failure or the CLI result object the
    /// agent forwards, so the user always sees *why* a turn failed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        turnId = try container.decodeIfPresent(String.self, forKey: .turnId)

        if let code = try container.decodeIfPresent(String.self, forKey: .code) {
            self.code = code
        } else if let status = try container.decodeIfPresent(Int.self, forKey: .apiErrorStatus) {
            self.code = "http_\(status)"
        } else {
            self.code = try container.decodeIfPresent(String.self, forKey: .subtype) ?? "turn_failed"
        }

        let stated =
            try container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .result)
        // Some CLI failures carry only a subtype — `error_during_execution`,
        // for example. Showing the code beats showing an empty row.
        self.message = stated?.isEmpty == false ? stated! : self.code
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(turnId, forKey: .turnId)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
    }
}

public enum ConversationEvent: Sendable, Hashable {
    case started(ConversationStarted)
    case userMessage(MessagePayload)
    case delta(MessagePayload)
    case messageCompleted(MessagePayload)
    case reasoningDelta(ReasoningPayload)
    case reasoningCompleted(ReasoningPayload)
    case toolStarted(ToolPayload)
    case toolUpdated(ToolPayload)
    case toolCompleted(ToolPayload)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(ApprovalResolution)
    case turnCompleted(TurnPayload)
    case turnFailed(TurnFailure)
    case turnInterrupted(TurnPayload)
    case providerStatusChanged(ProviderStatus)
    case providerLoginProgress(LoginProgress)
    case providerLoginCompleted(LoginOutcome)
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
    case providerAccounts = "provider.accounts"
    case providerAccountSave = "provider.account.save"
    case providerAccountDelete = "provider.account.delete"
    case providerAccountActivate = "provider.account.activate"
    case providerLogout = "provider.logout"
    case providerLoginStart = "provider.login.start"
    case providerLoginStatus = "provider.login.status"
    case providerLoginInput = "provider.login.input"
    case providerLoginCancel = "provider.login.cancel"
    case speechCredentials = "speech.credentials"
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
    /// Absolute paths on the Mac, already uploaded, that this message refers
    /// to. Omitted entirely when there are none, so an agent that predates
    /// attachments is handed exactly what it used to get.
    public let attachments: [String]?

    public init(
        provider: ProviderId, conversationId: String, text: String,
        attachments: [String]? = nil
    ) {
        self.provider = provider
        self.conversationId = conversationId
        self.text = text
        self.attachments = attachments?.isEmpty == true ? nil : attachments
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
            // Wording for each code is the app's own — see `RejectionReason`.
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

    public static func encodeEvent(_ envelope: EventEnvelope) throws -> Data {
        let payloadData: Data
        switch envelope.event {
        case let .started(payload): payloadData = try encoder.encode(payload)
        case let .userMessage(payload), let .delta(payload), let .messageCompleted(payload):
            payloadData = try encoder.encode(payload)
        case let .reasoningDelta(payload), let .reasoningCompleted(payload):
            payloadData = try encoder.encode(payload)
        case let .toolStarted(payload), let .toolUpdated(payload), let .toolCompleted(payload):
            payloadData = try encoder.encode(payload)
        case let .approvalRequested(payload): payloadData = try encoder.encode(payload)
        case let .approvalResolved(payload): payloadData = try encoder.encode(payload)
        case let .turnCompleted(payload), let .turnInterrupted(payload):
            payloadData = try encoder.encode(payload)
        case let .turnFailed(payload): payloadData = try encoder.encode(payload)
        case let .providerStatusChanged(payload): payloadData = try encoder.encode(payload)
        case let .providerLoginProgress(payload): payloadData = try encoder.encode(payload)
        case let .providerLoginCompleted(payload): payloadData = try encoder.encode(payload)
        case .unsupported:
            payloadData = Data("{}".utf8)
        }
        let payload = try JSONSerialization.jsonObject(with: payloadData)
        let object: [String: Any] = [
            "protocolVersion": envelope.protocolVersion,
            "messageId": envelope.messageId,
            "kind": EnvelopeKind.event.rawValue,
            "requestId": NSNull(),
            "sequence": envelope.sequence,
            "conversationId": (envelope.conversationId as Any?) ?? NSNull(),
            "type": envelope.rawType,
            "payload": payload,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
        case "conversation.reasoning_delta":
            return decode(ReasoningPayload.self).map(ConversationEvent.reasoningDelta)
                ?? .unsupported(rawType: rawType)
        case "conversation.reasoning_completed":
            return decode(ReasoningPayload.self).map(ConversationEvent.reasoningCompleted)
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
        case "provider.login.progress":
            return decode(LoginProgress.self).map(ConversationEvent.providerLoginProgress)
                ?? .unsupported(rawType: rawType)
        case "provider.login.completed":
            return decode(LoginOutcome.self).map(ConversationEvent.providerLoginCompleted)
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
