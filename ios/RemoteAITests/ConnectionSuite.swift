import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum ConnectionSuite {

    static func envelope(_ sequence: Int) -> EventEnvelope {
        EventEnvelope(
            sequence: sequence,
            conversationId: "codex-daily-1",
            rawType: "conversation.delta",
            event: .delta(MessagePayload(messageId: "m1", role: .assistant, text: "x"))
        )
    }

    /// Retry delays are recorded instead of slept so the suite stays fast.
    static let instantSleeper: @Sendable (TimeInterval) async -> Void = { _ in }

    public static let suite = TestSuite(
        name: "ConnectionSuite",
        cases: [
            TestCase("backoff grows exponentially and is capped") {
                let policy = BackoffPolicy(base: 0.5, multiplier: 2, cap: 8)
                try expectEqual(policy.delay(forAttempt: 0), 0.5)
                try expectEqual(policy.delay(forAttempt: 1), 1.0)
                try expectEqual(policy.delay(forAttempt: 2), 2.0)
                try expectEqual(policy.delay(forAttempt: 3), 4.0)
                try expectEqual(policy.delay(forAttempt: 4), 8.0)
                try expectEqual(policy.delay(forAttempt: 99), 8.0)
            },

            TestCase("the sequencer accepts strictly ascending events only") {
                var sequencer = EventSequencer()
                try expectTrue(sequencer.accept(envelope(1)))
                try expectTrue(sequencer.accept(envelope(2)))
                try expectFalse(sequencer.accept(envelope(2)), "duplicate must be dropped")
                try expectFalse(sequencer.accept(envelope(1)), "replayed older event must be dropped")
                try expectTrue(sequencer.accept(envelope(3)))
                try expectEqual(sequencer.lastSequence, 3)
            },

            TestCase("a redelivered burst after resume yields each event exactly once") {
                var sequencer = EventSequencer()
                let firstDelivery = [1, 2, 3, 4].map(envelope)
                let redelivered = [3, 4, 5, 6].map(envelope)

                var accepted: [Int] = []
                for event in firstDelivery + redelivered where sequencer.accept(event) {
                    accepted.append(event.sequence)
                }
                try expectEqual(accepted, [1, 2, 3, 4, 5, 6])
            },

            TestCase("a fresh coordinator is disconnected and refuses mutations") {
                let coordinator = await ConnectionCoordinator(transport: ScriptedTransport())
                try expectEqual(await coordinator.state, .disconnected)
                let error = try await expectThrows {
                    try await coordinator.requireOnline()
                }
                try expectEqual(error as? AgentClientError, .offline)
            },

            TestCase("connecting opens the transport without a resume cursor") {
                let transport = ScriptedTransport()
                let coordinator = await ConnectionCoordinator(transport: transport)
                try await coordinator.connect()
                try expectEqual(await coordinator.state, .online)
                try expectEqual(await transport.openCalls, [nil])
                try await coordinator.requireOnline()
            },

            TestCase("a drop while foregrounded retries with backoff and resumes from lastSequence") {
                let transport = ScriptedTransport(outcomes: [true, false, false, true])
                let coordinator = await ConnectionCoordinator(
                    transport: transport,
                    backoff: BackoffPolicy(base: 0.5, multiplier: 2, cap: 8),
                    sleeper: instantSleeper
                )
                try await coordinator.connect()
                _ = await coordinator.accept(envelope(5))
                await coordinator.transportDidDrop()
                try expectEqual(await coordinator.state, .recovering)

                try await coordinator.connect()
                try expectEqual(await coordinator.state, .online)
                try expectEqual(await transport.openCalls, [nil, 5, 5, 5])
                try expectEqual(await coordinator.recordedDelays, [0.5, 1.0])
            },

            TestCase("a backgrounded app does not reconnect") {
                let transport = ScriptedTransport(outcomes: [false])
                let coordinator = await ConnectionCoordinator(
                    transport: transport, sleeper: instantSleeper
                )
                await coordinator.setForeground(false)

                let error = try await expectThrows {
                    try await coordinator.connect()
                }
                try expectEqual(error as? AgentClientError, .transport("scripted_failure"))
                try expectEqual(await coordinator.state, .disconnected)
                try expectEqual(await transport.openCalls.count, 1, "no retry while backgrounded")
                try expectEqual(await coordinator.recordedDelays, [])
            },

            TestCase("exhausting the retry budget leaves the app offline and read-only") {
                let transport = ScriptedTransport(outcomes: [false, false, false])
                let coordinator = await ConnectionCoordinator(
                    transport: transport,
                    backoff: BackoffPolicy(base: 0.5, multiplier: 2, cap: 8),
                    maxAttempts: 3,
                    sleeper: instantSleeper
                )
                _ = try? await coordinator.connect()

                try expectEqual(await coordinator.state, .disconnected)
                try expectEqual(await transport.openCalls.count, 3)
                try expectEqual(await coordinator.recordedDelays, [0.5, 1.0])
                let error = try await expectThrows {
                    try await coordinator.requireOnline()
                }
                try expectEqual(error as? AgentClientError, .offline)
            },
        ]
    )
}
