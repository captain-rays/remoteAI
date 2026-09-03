import Foundation

/// Capped exponential backoff used for foreground reconnects.
public struct BackoffPolicy: Sendable, Hashable {
    public let base: TimeInterval
    public let multiplier: Double
    public let cap: TimeInterval

    public init(base: TimeInterval = 0.5, multiplier: Double = 2, cap: TimeInterval = 30) {
        self.base = base
        self.multiplier = multiplier
        self.cap = cap
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return min(base, cap) }
        let scaled = base * pow(multiplier, Double(attempt))
        return min(scaled, cap)
    }
}

/// Drops duplicate and replayed events so a resume after a dropped connection
/// delivers every event exactly once.
public struct EventSequencer: Sendable {
    public private(set) var lastSequence: Int

    public init(lastSequence: Int = 0) {
        self.lastSequence = lastSequence
    }

    public mutating func accept(_ envelope: EventEnvelope) -> Bool {
        guard envelope.sequence > lastSequence else { return false }
        lastSequence = envelope.sequence
        return true
    }

    /// Cursor to hand the agent when resuming. `nil` on a fresh connection.
    public var resumeCursor: Int? { lastSequence == 0 ? nil : lastSequence }
}

public protocol AgentTransport: Sendable {
    /// Opens the realtime channel, optionally asking the agent to replay from
    /// the last sequence this client accepted.
    func open(resumeFrom sequence: Int?) async throws -> AsyncStream<EventEnvelope>
    func close() async
}

/// Owns the connection lifecycle: state, reconnect policy and event ordering.
///
/// Reconnects happen only while the app is foregrounded; there is no background
/// task and no timer that touches the network on its own.
@MainActor
public final class ConnectionCoordinator {
    public private(set) var state: ConnectionState = .disconnected
    public private(set) var recordedDelays: [TimeInterval] = []
    public private(set) var isForeground = true

    private let transport: AgentTransport
    private let backoff: BackoffPolicy
    private let maxAttempts: Int
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private var sequencer = EventSequencer()

    public init(
        transport: AgentTransport,
        backoff: BackoffPolicy = BackoffPolicy(),
        maxAttempts: Int = 6,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.transport = transport
        self.backoff = backoff
        self.maxAttempts = maxAttempts
        self.sleeper = sleeper
    }

    public var lastSequence: Int { sequencer.lastSequence }

    public func setForeground(_ foreground: Bool) {
        isForeground = foreground
    }

    /// Passes an incoming event through the ordering guard.
    /// Returns `false` for duplicates and replays, which callers must ignore.
    @discardableResult
    public func accept(_ envelope: EventEnvelope) -> Bool {
        sequencer.accept(envelope)
    }

    /// Marks the channel as lost. The app stays read-only until `connect()`
    /// succeeds again.
    public func transportDidDrop() async {
        await transport.close()
        state = .recovering
    }

    @discardableResult
    public func connect() async throws -> AsyncStream<EventEnvelope> {
        if state != .recovering { state = .connecting }
        var attempt = 0

        while true {
            do {
                let stream = try await transport.open(resumeFrom: sequencer.resumeCursor)
                state = .online
                return stream
            } catch {
                attempt += 1
                let canRetry = isForeground && attempt < maxAttempts
                guard canRetry else {
                    state = .disconnected
                    throw error
                }
                state = .recovering
                let delay = backoff.delay(forAttempt: attempt - 1)
                recordedDelays.append(delay)
                await sleeper(delay)
            }
        }
    }

    public func disconnect() async {
        await transport.close()
        state = .disconnected
    }

    /// Gate for every mutating operation. Offline means read-only cache.
    public func requireOnline() throws {
        guard state.allowsMutation else { throw AgentClientError.offline }
    }
}
