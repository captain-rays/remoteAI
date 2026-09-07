import Foundation
import RemoteAIKit
import RemoteAITestKit

/// What the phone shows when the trouble is the provider, not the request.
///
/// A turn failure belongs in its conversation. "This account is out of
/// credit" does not: it applies to every conversation of that provider, and
/// the way out — top up, or sign in again — has nothing to do with whichever
/// conversation happens to be open.
public enum ProviderHealthSuite {

    private static func status(
        _ provider: ProviderId,
        problem: ProviderProblem? = nil,
        login: ProviderLogin? = nil
    ) -> ProviderStatus {
        ProviderStatus(
            provider: provider, available: true, executablePath: "/usr/bin/x",
            login: login, problem: problem
        )
    }

    public static let suite = TestSuite(
        name: "ProviderHealthSuite",
        cases: [
            TestCase("the reason names the provider, which the Mac's message does not") {
                // "You've hit your usage limit" does not say whose limit.
                let problem = ProviderProblem(
                    code: .quotaExhausted, message: "You've hit your usage limit."
                )
                try expectEqual(problem.headline(for: .codex), "Codex has run out of credit")
                try expectEqual(problem.headline(for: .claude), "Claude has run out of credit")
            },

            TestCase("only an expired login asks the reader to sign in") {
                try expectTrue(
                    ProviderProblem(code: .loginExpired, message: "401").needsLogin
                )
                for code in [
                    ProviderProblemCode.quotaExhausted, .rateLimited, .modelUnavailable,
                ] {
                    try expectFalse(
                        ProviderProblem(code: code, message: "x").needsLogin,
                        "\(code) is not fixed by signing in"
                    )
                }
            },

            TestCase("a problem code this build does not know still carries its message") {
                // The Mac may learn to classify something this app has never
                // heard of. Swallowing it would hide a real refusal.
                let decoded = try JSONDecoder().decode(
                    ProviderProblem.self,
                    from: Data(
                        #"{"code":"solar_flare","message":"the sun did it"}"#.utf8
                    )
                )
                try expectEqual(decoded.code, .unknown)
                try expectEqual(decoded.message, "the sun did it")
                try expectEqual(decoded.headline(for: .codex), "Codex reported a problem")
            },

            TestCase("a provider whose login could not be read is not called logged out") {
                let unreadable = try JSONDecoder().decode(
                    ProviderStatus.self,
                    from: Data(#"{"provider":"claude","available":true}"#.utf8)
                )
                try expectNil(unreadable.login)

                let unknown = try JSONDecoder().decode(
                    ProviderStatus.self,
                    from: Data(
                        #"{"provider":"claude","available":true,"login":{"state":"unknown"}}"#.utf8
                    )
                )
                try expectEqual(unknown.login?.state, .unknown)

                let out = try JSONDecoder().decode(
                    ProviderStatus.self,
                    from: Data(
                        #"{"provider":"claude","available":true,"login":{"state":"logged_out"}}"#
                            .utf8
                    )
                )
                try expectEqual(out.login?.state, .loggedOut)
            },

            TestCase("a login state this build does not know reads as unknown, not signed in") {
                let decoded = try JSONDecoder().decode(
                    ProviderLogin.self,
                    from: Data(#"{"state":"pending_sms","account":"a@b.c"}"#.utf8)
                )
                try expectEqual(decoded.state, .unknown)
            },

            TestCase("a standing problem reaches the app from the status it already reads") {
                let client = StatusStubClient(statuses: [
                    status(
                        .codex,
                        problem: ProviderProblem(
                            code: .quotaExhausted, message: "You've hit your usage limit."
                        )
                    ),
                    status(.claude, login: ProviderLogin(state: .loggedIn, account: "a@b.c")),
                ])
                let model = await MainActor.run {
                    AppModel(
                        client: client, preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache()
                    )
                }
                await MainActor.run { model.setConnectionState(.online) }
                await model.refreshProviderStatuses()

                try expectEqual(await model.problem(for: .codex)?.code, .quotaExhausted)
                try expectNil(
                    await model.problem(for: .claude),
                    "one provider's problem is not the other's"
                )
                try expectEqual(await model.login(for: .claude)?.account, "a@b.c")
            },

            TestCase("a failed turn makes the app ask the Mac what is wrong") {
                // Without this the banner only appears on the next catalog
                // reload, which may be minutes after the failure.
                let client = StatusStubClient(statuses: [status(.codex)])
                let model = await MainActor.run {
                    AppModel(
                        client: client, preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache()
                    )
                }
                await MainActor.run { model.setConnectionState(.online) }
                let before = await client.reads

                _ = await MainActor.run {
                    model.handle(
                        EventEnvelope(
                            sequence: 1, conversationId: "codex-daily-1",
                            rawType: "turn.failed",
                            event: .turnFailed(
                                TurnFailure(turnId: "t1", code: "provider_error", message: "no")
                            )
                        )
                    )
                }

                try await expectEventually(
                    "the app re-reads provider status after a failure"
                ) { await client.reads > before }
            },

            TestCase("a turn completing while nothing is wrong costs no extra round trip") {
                let client = StatusStubClient(statuses: [status(.codex)])
                let model = await MainActor.run {
                    AppModel(
                        client: client, preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache()
                    )
                }
                await MainActor.run { model.setConnectionState(.online) }
                await model.refreshProviderStatuses()
                let before = await client.reads

                _ = await MainActor.run {
                    model.handle(
                        EventEnvelope(
                            sequence: 1, conversationId: "codex-daily-1",
                            rawType: "turn.completed",
                            event: .turnCompleted(TurnPayload(turnId: "t1"))
                        )
                    )
                }
                // Give any stray task a chance to run before asserting a
                // negative.
                try? await Task.sleep(for: .milliseconds(120))
                try expectEqual(await client.reads, before)
            },
        ]
    )
}

/// Answers `providerStatus` from a fixed list and counts the asking.
private actor StatusStubClient: StubAgentClient {
    private let statuses: [ProviderStatus]
    private(set) var reads = 0

    init(statuses: [ProviderStatus]) { self.statuses = statuses }

    func providerStatus() async throws -> [ProviderStatus] {
        reads += 1
        return statuses
    }

    func listDailyConversations(provider: ProviderId) async throws -> [ConversationSummary] { [] }
    func listProjects(provider: ProviderId) async throws -> [ProjectSummary] { [] }
}
