import Foundation
import RemoteAIKit

/// Test double for `AgentTransport` whose successes and failures are scripted
/// up front, so reconnect behaviour is deterministic.
public actor ScriptedTransport: AgentTransport {
    private var outcomes: [Bool]
    private var index = 0
    public private(set) var openCalls: [Int?] = []
    public private(set) var closeCount = 0

    public init(outcomes: [Bool] = [true]) {
        self.outcomes = outcomes
    }

    public func open(resumeFrom sequence: Int?) async throws -> AsyncStream<EventEnvelope> {
        openCalls.append(sequence)
        let succeeds = index < outcomes.count ? outcomes[index] : outcomes.last ?? true
        index += 1
        guard succeeds else { throw AgentClientError.transport("scripted_failure") }
        return AsyncStream { $0.finish() }
    }

    public func close() async {
        closeCount += 1
    }
}
