import Foundation
import Observation

/// The accounts screen for one provider.
///
/// Sign-in happens on the Mac, in the CLI's own flow, and this watches it by
/// asking rather than listening: the phone's socket lives for one request, so
/// an event sent while nothing was connected would be lost. Asking once a
/// second is cheap next to a flow that waits on a person and a browser.
@MainActor
@Observable
public final class AccountsViewModel {
    public let provider: ProviderId
    private let client: AgentClient

    public private(set) var accounts: [AccountEntry] = []
    public private(set) var login: ProviderLogin = ProviderLogin(state: .unknown)
    public private(set) var isLoading = false
    /// Set while a request is in flight, so the screen can stop offering the
    /// same button twice.
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?
    /// The sign-in in progress, as the Mac last reported it.
    public private(set) var signIn: LoginProgress?
    /// Why the last sign-in did not work.
    public private(set) var signInFailure: String?

    /// How often a running sign-in is asked about.
    private let pollEvery: Duration
    private var poller: Task<Void, Never>?

    public init(
        provider: ProviderId, client: AgentClient, pollEvery: Duration = .seconds(1)
    ) {
        self.provider = provider
        self.client = client
        self.pollEvery = pollEvery
    }

    /// Stop watching a running sign-in. Called when the screen goes away:
    /// the flow keeps running on the Mac and is picked up again on the next
    /// `load()`.
    public func stopWatching() {
        poller?.cancel()
        poller = nil
    }

    /// Whether the provider is signed in as far as the Mac could tell.
    public var isSignedIn: Bool { login.state == .loggedIn }

    /// What to show as the current account.
    public var currentAccountDescription: String {
        switch login.state {
        case .loggedIn:
            let name = login.account ?? "an account"
            return [name, login.detail].compactMap { $0 }.joined(separator: " — ")
        case .loggedOut:
            return "Not signed in"
        case .unknown:
            // Distinct from "not signed in": the Mac could not ask, and
            // sending someone to re-authenticate on that basis wastes their
            // time.
            return "Sign-in state unknown"
        }
    }

    public func load() async {
        isLoading = true
        await apply { try await self.client.accounts(provider: self.provider) }
        isLoading = false
        // A sign-in another phone — or the reader, earlier — started is still
        // running, and should be joined rather than hidden.
        if signIn == nil,
            let running = try? await client.loginProgress(provider: provider)
        {
            signIn = running
            startPolling()
        }
    }

    public func save(label: String) async {
        await apply { try await self.client.saveAccount(provider: self.provider, label: label) }
    }

    public func delete(label: String) async {
        await apply { try await self.client.deleteAccount(provider: self.provider, label: label) }
    }

    public func activate(label: String) async {
        await apply {
            try await self.client.activateAccount(provider: self.provider, label: label)
        }
    }

    public func signOut() async {
        await apply { try await self.client.logout(provider: self.provider) }
    }

    /// Start the CLI's sign-in flow. `label` is where the credential is filed
    /// if it works; without one the sign-in still happens, but leaves nothing
    /// to switch back to.
    public func startSignIn(label: String?) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        signInFailure = nil
        do {
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            signIn = try await client.startLogin(
                provider: provider, label: (trimmed?.isEmpty ?? true) ? nil : trimmed
            )
            startPolling()
            // Starting a sign-in signs out of the account in use, to make
            // room for the new one. The screen has to show that, or it keeps
            // naming an account the CLI no longer holds.
            if let view = try? await client.accounts(provider: provider) {
                adopt(view)
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
        isWorking = false
    }

    /// Answer the flow's prompt — the verification code.
    public func submit(code: String) async {
        guard let session = signIn?.sessionId else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await client.sendLoginInput(
                provider: provider, sessionId: session, text: trimmed
            )
        } catch {
            errorMessage = Self.message(for: error)
        }
        isWorking = false
    }

    public func cancelSignIn() async {
        guard let session = signIn?.sessionId else { return }
        poller?.cancel()
        poller = nil
        signIn = nil
        try? await client.cancelLogin(provider: provider, sessionId: session)
        await load()
    }

    /// Watch a running sign-in until it ends, then say how it went.
    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.pollEvery)
                if Task.isCancelled { return }
                let progress: LoginProgress?
                do {
                    progress = try await self.client.loginProgress(provider: self.provider)
                } catch {
                    // A poll that could not reach the Mac says nothing about
                    // the sign-in, which is running there and not here. Keep
                    // the screen — and the reply field — and ask again on the
                    // next tick.
                    self.errorMessage = Self.message(for: error)
                    continue
                }
                guard let running = progress else {
                    // The Mac has no session any more, so it ended. Whether
                    // that counted as signing in is what the accounts read
                    // inside `finishSignIn` answers.
                    await self.finishSignIn()
                    return
                }
                self.errorMessage = nil
                self.signIn = running
            }
        }
    }

    private func finishSignIn() async {
        signIn = nil
        poller = nil
        await load()
        if !isSignedIn {
            // The Mac keeps the CLI's own last words for exactly this: the
            // flow may have ended while this phone was not connected.
            signInFailure = lastMessage ?? "Signing in did not complete."
        }
    }

    private var lastMessage: String?

    /// Runs one account request and adopts its answer.
    private func apply(_ operation: @escaping () async throws -> AccountsView) async {
        isWorking = true
        errorMessage = nil
        do {
            adopt(try await operation())
        } catch {
            errorMessage = Self.message(for: error)
        }
        isWorking = false
    }

    private func adopt(_ view: AccountsView) {
        accounts = view.accounts
        login = view.login
        lastMessage = view.lastLoginMessage
    }

    /// Wording for the Mac's refusals.
    ///
    /// The Mac sends a code, never a sentence — a provider's own error text
    /// can carry prompt content — so the sentence is the app's.
    public static func message(for error: Error) -> String {
        guard case let AgentClientError.rejected(code) = error else {
            return AppModel.userMessage(for: error)
        }
        switch code {
        case "nothing_signed_in":
            return "Nothing is signed in yet, so there is no account to save."
        case "account_credential_missing":
            return "That account's saved sign-in is gone from the Mac's keychain. Sign in again."
        case "account_credential_rejected":
            return "The Mac restored that account, but the CLI would not accept it. Sign in again."
        case "login_not_running":
            return "That sign-in has already finished. Start it again."
        case "invalid_account_label":
            return "Use letters, digits, spaces and - _ . @ for the account name."
        case "login_not_started":
            return "The sign-in could not be started on the Mac."
        case "account_operation_failed":
            return "The Mac could not complete that."
        case "provider_unavailable":
            return "That CLI is not installed on the Mac."
        default:
            return AppModel.userMessage(for: error)
        }
    }
}
