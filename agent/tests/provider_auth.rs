//! Reading each CLI's own account state.
//!
//! Both CLIs will tell you who is logged in, in their own format. Parsing is
//! kept separate from spawning so the wording each one uses is pinned by a
//! test instead of discovered in production.

use remote_ai_agent::auth::{LoginState, parse_claude_auth_status, parse_codex_login_status};

#[test]
fn claude_reports_the_account_it_is_signed_in_as() {
    let status = parse_claude_auth_status(
        r#"{
            "loggedIn": true,
            "authMethod": "claude.ai",
            "apiProvider": "firstParty",
            "email": "someone@example.com",
            "orgId": "5b73aacb",
            "orgName": "Beem Organization",
            "subscriptionType": "team"
        }"#,
    );
    assert_eq!(status.state, LoginState::LoggedIn);
    assert_eq!(status.account.as_deref(), Some("someone@example.com"));
    assert_eq!(status.detail.as_deref(), Some("Beem Organization · team"));
}

#[test]
fn a_logged_out_claude_says_so_without_naming_an_account() {
    let status = parse_claude_auth_status(r#"{"loggedIn": false}"#);
    assert_eq!(status.state, LoginState::LoggedOut);
    assert_eq!(status.account, None);
}

#[test]
fn claude_signed_in_with_an_api_key_still_names_something() {
    // Console billing has no email; the method is the only identity there is.
    let status = parse_claude_auth_status(
        r#"{"loggedIn": true, "authMethod": "console", "apiProvider": "firstParty"}"#,
    );
    assert_eq!(status.state, LoginState::LoggedIn);
    assert_eq!(status.account.as_deref(), Some("console"));
}

#[test]
fn codex_reports_the_method_it_is_signed_in_with() {
    let status = parse_codex_login_status("Logged in using ChatGPT\n");
    assert_eq!(status.state, LoginState::LoggedIn);
    assert_eq!(status.account.as_deref(), Some("ChatGPT"));
}

#[test]
fn codex_reports_being_logged_out() {
    let status = parse_codex_login_status("Not logged in\n");
    assert_eq!(status.state, LoginState::LoggedOut);
    assert_eq!(status.account, None);
}

#[test]
fn output_neither_cli_was_expected_to_produce_is_not_a_claim_about_login() {
    // Telling someone they are logged out because we could not parse the
    // answer would send them to re-authenticate for nothing.
    for text in ["", "Segmentation fault", "{ not json"] {
        assert_eq!(
            parse_codex_login_status(text).state,
            LoginState::Unknown,
            "{text:?}"
        );
        assert_eq!(
            parse_claude_auth_status(text).state,
            LoginState::Unknown,
            "{text:?}"
        );
    }
}
