import SwiftUI

/// The accounts for one provider: which one is in use, which others are saved,
/// and a way to sign in.
///
/// Sign-in runs on the Mac in the CLI's own flow, so what is shown here is
/// whatever it printed — a link, a code, a prompt — rather than a form this
/// app invented.
@MainActor
public struct ProviderAccountsView: View {
    @Bindable private var model: AccountsViewModel
    @State private var newAccountLabel = ""
    @State private var code = ""
    @State private var labelForSignIn = ""
    @State private var isSigningIn = false

    public init(model: AccountsViewModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("Signed in as") {
                LabeledContent(
                    model.provider.displayName, value: model.currentAccountDescription
                )
                .accessibilityIdentifier("current-account")

                if let failure = model.signInFailure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("sign-in-failure")
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("accounts-error")
                }

                Button("Sign in…") {
                    labelForSignIn = ""
                    isSigningIn = true
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("sign-in")

                if model.isSignedIn {
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("sign-out")
                }
            }

            Section {
                if model.accounts.isEmpty {
                    Text("No accounts saved on the Mac yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("no-saved-accounts")
                }
                ForEach(model.accounts) { account in
                    AccountRow(account: account) {
                        Task { await model.activate(label: account.label) }
                    } onDelete: {
                        Task { await model.delete(label: account.label) }
                    }
                    .disabled(model.isWorking)
                }
            } header: {
                Text("Saved accounts")
            } footer: {
                Text(
                    "Saving keeps a copy of the current sign-in in the Mac's keychain, "
                        + "so you can switch back to it from here."
                )
            }

            Section("Save the current sign-in") {
                PlainTextField("Account name", text: $newAccountLabel)
                    .accessibilityIdentifier("new-account-label")
                Button("Save") {
                    let label = newAccountLabel
                    newAccountLabel = ""
                    Task { await model.save(label: label) }
                }
                .disabled(
                    model.isWorking
                        || newAccountLabel.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .accessibilityIdentifier("save-account")
            }
        }
        .navigationTitle("\(model.provider.displayName) account")
        .task { await model.load() }
        .onDisappear { model.stopWatching() }
        .sheet(isPresented: $isSigningIn) {
            SignInSheet(model: model, label: $labelForSignIn, code: $code)
        }
        .onChange(of: model.signIn == nil) { _, finished in
            // The sheet closes when the Mac says the flow is over, whether it
            // worked or not — the outcome is on the screen behind it.
            if finished { isSigningIn = false }
        }
    }
}

private struct AccountRow: View {
    let account: AccountEntry
    let onUse: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                    .accessibilityIdentifier("account-\(account.label)")
                if let display = account.display {
                    Text(display).font(.caption).foregroundStyle(.secondary)
                }
                if !account.hasCredential {
                    // The entry outlived its keychain item. Offering to switch
                    // to it would only fail.
                    Text("Saved sign-in is missing — sign in again")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if account.isCurrent {
                Image(systemName: "checkmark")
                    .accessibilityLabel("In use")
            } else if account.hasCredential {
                Button("Use", action: onUse)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("use-account-\(account.label)")
            }
        }
        // No identifier on the row itself: SwiftUI folds a container's
        // identifier onto the one control inside it, which took the name of
        // the "Use" button and left the row unaddressable.
        .swipeActions {
            Button("Delete", role: .destructive, action: onDelete)
                .accessibilityIdentifier("delete-account-\(account.label)")
        }
    }
}

/// The CLI's sign-in flow, as it happens.
private struct SignInSheet: View {
    @Bindable var model: AccountsViewModel
    @Binding var label: String
    @Binding var code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let flow = model.signIn {
                    if let url = flow.verificationUrl, let link = URL(string: url) {
                        Section("1. Open this and sign in to the account you want") {
                            Link(url, destination: link)
                                .accessibilityIdentifier("sign-in-url")
                        }
                    }
                    if let userCode = flow.userCode {
                        // The code box only appears once you are signed in:
                        // the page has to know which account is authorising.
                        // Omitting that step sent a reader straight to a login
                        // page they were not expecting.
                        Section("2. Once signed in, enter this code") {
                            Text(userCode)
                                .font(.title3.monospaced())
                                .textSelection(.enabled)
                                .accessibilityIdentifier("sign-in-user-code")
                        }
                    }
                    // Always available while the flow runs, not only when
                    // the output looks like a prompt. These CLIs also ask
                    // things we cannot anticipate — Claude stops on an
                    // organisation's managed-settings confirmation whose last
                    // line reads "Enter to confirm" — and a reader who cannot
                    // answer is stuck with no way forward.
                    Section(
                        flow.awaitingInput
                            ? "Code from the browser" : "Reply to the Mac"
                    ) {
                        PlainTextField(
                            flow.awaitingInput ? "Verification code" : "Type a reply",
                            text: $code
                        )
                        .accessibilityIdentifier("sign-in-code")
                        Button(flow.awaitingInput ? "Send code" : "Send") {
                            let entered = code
                            code = ""
                            Task { await model.submit(code: entered) }
                        }
                        .disabled(
                            model.isWorking
                                || code.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                        .accessibilityIdentifier("send-code")
                    }
                    if let error = model.errorMessage {
                        Section {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("sign-in-error")
                        }
                    }
                    Section("What the Mac is showing") {
                        // Verbatim: it is the only account of what the flow is
                        // doing, and its wording is not ours. Until it prints
                        // something, say so — an empty box reads as a button
                        // that did nothing.
                        Text(
                            flow.output.isEmpty
                                ? "Waiting for the Mac to start the sign-in…" : flow.output
                        )
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("sign-in-output")
                    }
                    Section {
                        Button("Cancel sign-in", role: .destructive) {
                            Task {
                                await model.cancelSignIn()
                                dismiss()
                            }
                        }
                        .accessibilityIdentifier("cancel-sign-in")
                    }
                } else {
                    Section {
                        PlainTextField("Save this account as (optional)", text: $label)
                            .accessibilityIdentifier("sign-in-label")
                        Button("Start sign-in on the Mac") {
                            Task { await model.startSignIn(label: label) }
                        }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("start-sign-in")
                        if let error = model.errorMessage {
                            // This used to be rendered on the screen behind
                            // the sheet, so a refused start looked like a
                            // button that did nothing at all.
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("start-sign-in-error")
                        }
                    } footer: {
                        Text(
                            "The Mac runs \(model.provider.displayName)'s own sign-in. "
                                + "Signing in replaces the account it is using now; if that "
                                + "one is saved here you can switch back to it."
                        )
                    }
                }
            }
            .navigationTitle("Sign in")
        }
    }
}

/// A text field for something that is not prose — an account name, a
/// verification code.
///
/// Autocapitalisation would turn `work` into `Work` and a code into something
/// the CLI rejects. The modifier that turns it off exists only on iOS, so it
/// is confined here instead of guarded at every call site.
private struct PlainTextField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        let field = TextField(title, text: $text).autocorrectionDisabled()
        #if os(iOS)
            return field.textInputAutocapitalization(.never)
        #else
            return field
        #endif
    }
}
