//! What the phone is told when a provider itself is the problem.
//!
//! A turn that fails because the account is out of credit reads, in the
//! transcript, exactly like a turn that failed for any other reason: one red
//! line inside one conversation. The person holding the phone has no way to
//! tell "this conversation broke" from "this provider will refuse everything
//! until you top up or log in again". These tests pin the classification that
//! makes the difference visible.

use remote_ai_agent::health::{ProblemCode, ProblemLog, classify_problem};
use remote_ai_agent::protocol::ProviderId;
use serde_json::json;

#[test]
fn hitting_the_usage_limit_is_reported_as_exhausted_quota() {
    // Codex's own wording, from a turn that really failed this way.
    let message = "You've hit your usage limit. Upgrade to Pro \
                   (https://chatgpt.com/explore/pro), visit \
                   https://chatgpt.com/codex/settings/usage to purchase more \
                   credits or try again at 9:49 PM.";
    assert_eq!(classify_problem(message), Some(ProblemCode::QuotaExhausted));
}

#[test]
fn a_low_credit_balance_is_reported_as_exhausted_quota() {
    assert_eq!(
        classify_problem(
            "Your credit balance is too low to access the Anthropic API. \
             Please go to Plans & Billing to upgrade or purchase credits."
        ),
        Some(ProblemCode::QuotaExhausted)
    );
}

#[test]
fn an_expired_login_is_reported_as_an_expired_login() {
    for message in [
        "OAuth token has expired. Please run /login",
        "401 Unauthorized",
        "Not logged in. Run `codex login` to authenticate.",
        "invalid_api_key: your authentication credentials are not valid",
    ] {
        assert_eq!(
            classify_problem(message),
            Some(ProblemCode::LoginExpired),
            "{message:?} should read as an expired login"
        );
    }
}

#[test]
fn a_retired_model_is_reported_as_an_unavailable_model() {
    for message in [
        "The model `gpt-5.3-codex` does not exist or you do not have access to it.",
        "model_not_found",
        "This model has been retired.",
    ] {
        assert_eq!(
            classify_problem(message),
            Some(ProblemCode::ModelUnavailable),
            "{message:?} should read as an unavailable model"
        );
    }
}

#[test]
fn a_rate_limit_is_not_the_same_as_running_out_of_credit() {
    // One clears by waiting a minute; the other needs the person to go and
    // buy something. Telling them to top up when they only need to wait is
    // worse than saying nothing.
    assert_eq!(
        classify_problem("429 Too Many Requests: rate limit exceeded, retry after 30s"),
        Some(ProblemCode::RateLimited)
    );
}

#[test]
fn an_ordinary_failure_is_not_dressed_up_as_a_provider_problem() {
    // The transcript already shows this. A banner claiming the account is
    // broken would be a lie.
    for message in [
        "No conversation found with session ID abc",
        "the tool call was interrupted",
        "",
    ] {
        assert_eq!(classify_problem(message), None, "{message:?}");
    }
}

#[test]
fn a_providers_problem_is_remembered_until_a_turn_succeeds() {
    let health = ProblemLog::default();
    assert!(health.problem(ProviderId::Codex).is_none());

    health.record_turn_failure(
        ProviderId::Codex,
        &json!({"code": "provider_error", "message": "You've hit your usage limit."}),
    );

    let problem = health.problem(ProviderId::Codex).expect("a problem");
    assert_eq!(problem.code, ProblemCode::QuotaExhausted);
    assert!(problem.message.contains("usage limit"));

    // The next turn going through is the only evidence that it is over.
    health.record_turn_completed(ProviderId::Codex);
    assert!(health.problem(ProviderId::Codex).is_none());
}

#[test]
fn one_providers_problem_says_nothing_about_the_other() {
    let health = ProblemLog::default();
    health.record_turn_failure(
        ProviderId::Codex,
        &json!({"message": "Your credit balance is too low"}),
    );

    assert!(health.problem(ProviderId::Codex).is_some());
    assert!(
        health.problem(ProviderId::Claude).is_none(),
        "Codex being out of credit must not stop the phone using Claude"
    );
}

#[test]
fn a_failure_that_names_no_cause_leaves_no_standing_problem() {
    let health = ProblemLog::default();
    health.record_turn_failure(
        ProviderId::Claude,
        &json!({"code": "cli_produced_no_output", "message": "the CLI wrote nothing"}),
    );
    assert!(health.problem(ProviderId::Claude).is_none());
}
