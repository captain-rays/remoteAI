import Foundation
import RemoteAIKit
import RemoteAITestKit

/// The accounts screen, driven against the in-process mock agent — which
/// mirrors the Mac's rules: one current account per provider, signing in
/// replaces the current credential, deleting a saved account does not sign
/// out of it.
public enum AccountsViewModelSuite {

    @MainActor
    private static func model(
        _ provider: ProviderId = .claude, client: AgentClient = MockAgentClient()
    ) -> AccountsViewModel {
        // Poll fast: these tests wait on the sign-in ending, not on a clock.
        AccountsViewModel(provider: provider, client: client, pollEvery: .milliseconds(10))
    }

    public static let suite = TestSuite(
        name: "AccountsViewModelSuite",
        cases: [
            TestCase("the current account is named, not just counted") {
                let model = await MainActor.run { AccountsViewModelSuite.model() }
                await model.load()

                try expectTrue(await model.isSignedIn)
                try expectEqual(
                    await model.currentAccountDescription,
                    "someone@example.com — Mock org · team"
                )
            },

            TestCase("a sign-in state the Mac could not read is not read as signed out") {
                // Being told to sign in again when nothing is wrong wastes a
                // trip to the Mac.
                let model = await MainActor.run { AccountsViewModelSuite.model() }
                try expectEqual(
                    await model.currentAccountDescription, "Sign-in state unknown"
                )
                try expectFalse(await model.isSignedIn)
            },

            TestCase("an account can be saved and switched back to") {
                let model = await MainActor.run { AccountsViewModelSuite.model(.codex) }
                await model.load()
                try expectEqual(await model.accounts.map(\.label), ["work"])

                await model.save(label: "personal")
                try expectEqual(await model.accounts.map(\.label), ["personal", "work"])
                try expectEqual(
                    await model.accounts.filter(\.isCurrent).map(\.label), ["personal"],
                    "exactly one account is current"
                )

                await model.activate(label: "work")
                try expectEqual(
                    await model.accounts.filter(\.isCurrent).map(\.label), ["work"]
                )
                try expectTrue(await model.isSignedIn)
                try expectNil(await model.errorMessage)
            },

            TestCase("saving with nothing signed in explains what to do instead") {
                // `nothing_signed_in` is the Mac's whole answer; the sentence
                // is the app's.
                let client = MockAgentClient()
                let model = await MainActor.run { AccountsViewModelSuite.model(.claude, client: client) }
                await model.load()
                await model.signOut()

                await model.save(label: "work")

                try expectEqual(
                    await model.errorMessage,
                    "Nothing is signed in yet, so there is no account to save."
                )
            },

            TestCase("signing out leaves the saved accounts there to switch to") {
                let model = await MainActor.run { AccountsViewModelSuite.model(.codex) }
                await model.load()

                await model.signOut()

                try expectFalse(await model.isSignedIn)
                try expectEqual(await model.accounts.map(\.label), ["work"])
                try expectTrue(
                    await model.accounts.allSatisfy { !$0.isCurrent },
                    "nothing is current while signed out"
                )

                await model.activate(label: "work")
                try expectTrue(await model.isSignedIn)
            },

            TestCase("deleting a saved account does not sign out of it") {
                let model = await MainActor.run { AccountsViewModelSuite.model(.codex) }
                await model.load()

                await model.delete(label: "work")

                try expectTrue(await model.accounts.isEmpty)
                try expectTrue(
                    await model.isSignedIn,
                    "deleting a copy is housekeeping, not a request to sign out"
                )
            },

            TestCase("signing in shows the link and the code and takes one back") {
                let model = await MainActor.run { AccountsViewModelSuite.model(.claude) }
                await model.load()

                await model.startSignIn(label: "new")

                let flow = try expectNotNil(await model.signIn)
                try expectEqual(flow.verificationUrl, "https://auth.example.com/device")
                try expectEqual(flow.userCode, "MOCK-CODE1")
                try expectTrue(flow.awaitingInput)
                try expectFalse(
                    await model.isSignedIn,
                    "signing in signs out of the old account first"
                )

                await model.submit(code: MockAgentClient.mockLoginCode)

                try await expectEventually("the sign-in finishes") {
                    await MainActor.run { model.signIn == nil && model.isSignedIn }
                }
                try expectEqual(await model.login.account, "mock@example.com")
                try expectEqual(
                    await model.accounts.filter(\.isCurrent).map(\.label), ["new"],
                    "the new account was filed under the name given"
                )
                try expectNil(await model.signInFailure)
            },

            TestCase("a rejected code is reported in the CLI's own words") {
                let model = await MainActor.run { AccountsViewModelSuite.model(.claude) }
                await model.load()
                await model.startSignIn(label: "new")

                await model.submit(code: "000000")

                try await expectEventually("the failure is reported") {
                    await MainActor.run { model.signInFailure != nil }
                }
                try expectEqual(await model.signInFailure, "That code was rejected")
                try expectFalse(await model.isSignedIn)
                try expectTrue(
                    await model.accounts.isEmpty, "a failed sign-in files nothing"
                )
            },

            TestCase("reopening the screen rejoins a sign-in that is still running") {
                // The flow lives on the Mac. Coming back to a blank screen
                // would look like it had died, and starting another would
                // replace the credential the first is about to write.
                let client = MockAgentClient()
                let first = await MainActor.run { AccountsViewModelSuite.model(.claude, client: client) }
                await first.load()
                await first.startSignIn(label: "new")
                await MainActor.run { first.stopWatching() }
                let session = try expectNotNil(await first.signIn).sessionId

                let second = await MainActor.run { AccountsViewModelSuite.model(.claude, client: client) }
                await second.load()

                try expectEqual(await second.signIn?.sessionId, session)
            },

            TestCase("cancelling a sign-in stops it on the Mac too") {
                let client = MockAgentClient()
                let model = await MainActor.run { AccountsViewModelSuite.model(.claude, client: client) }
                await model.load()
                await model.startSignIn(label: "new")

                await model.cancelSignIn()

                try expectNil(await model.signIn)
                try expectNil(
                    try await client.loginProgress(provider: .claude),
                    "the Mac is not left running a flow nobody is watching"
                )
            },

            TestCase("a name the Mac would refuse is explained, not just rejected") {
                let model = await MainActor.run { AccountsViewModelSuite.model(.claude, client: RefusingClient()) }

                await model.save(label: "claude:work")

                try expectEqual(
                    await model.errorMessage,
                    "Use letters, digits, spaces and - _ . @ for the account name."
                )
            },

            TestCase("a provider whose CLI is missing says so") {
                let model = await MainActor.run { AccountsViewModelSuite.model(.claude, client: MissingCLIClient()) }
                await model.load()
                try expectEqual(
                    await model.errorMessage, "That CLI is not installed on the Mac."
                )
            },
        ]
    )
}

/// Refuses every account request with the Mac's label error.
private actor RefusingClient: StubAgentClient {
    func saveAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        throw AgentClientError.rejected("invalid_account_label")
    }
}

private actor MissingCLIClient: StubAgentClient {
    func accounts(provider: ProviderId) async throws -> AccountsView {
        throw AgentClientError.rejected("provider_unavailable")
    }
    func loginProgress(provider: ProviderId) async throws -> LoginProgress? { nil }
}
