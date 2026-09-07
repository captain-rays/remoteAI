//! Whether a provider is currently able to work at all.
//!
//! A failed turn is shown in its conversation, which is the right place for
//! "this exchange broke". It is the wrong place for "this account is out of
//! credit", because that answer applies to every conversation of that
//! provider and needs an action — top up, or log in again — that has nothing
//! to do with the conversation the person happens to be looking at.
//!
//! So failures whose wording names such a cause are classified here and
//! remembered per provider until a turn goes through.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::protocol::ProviderId;

/// Why a provider will keep refusing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProblemCode {
    /// The account has no credit or allowance left. Needs the person to buy
    /// or upgrade something; waiting will not help.
    QuotaExhausted,
    /// Too many requests too quickly. Clears on its own.
    RateLimited,
    /// The credential is gone or no longer accepted.
    LoginExpired,
    /// The model this conversation is pinned to cannot be used.
    ModelUnavailable,
}

impl ProblemCode {
    /// Whether re-authenticating is what would fix this.
    pub fn is_login_problem(self) -> bool {
        matches!(self, ProblemCode::LoginExpired)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderProblem {
    pub code: ProblemCode,
    /// The provider's own words, kept verbatim: it usually contains the thing
    /// the person needs (a link, or the hour the limit resets).
    pub message: String,
    pub observed_at: DateTime<Utc>,
}

/// Classify a provider's failure message, or `None` when it names no cause we
/// can act on.
///
/// Matching is on wording rather than error codes because neither CLI offers a
/// stable machine-readable reason for these: the message is what they give us.
/// A message that matches nothing deliberately produces no problem at all —
/// claiming the account is broken on a guess is worse than staying quiet.
pub fn classify_problem(message: &str) -> Option<ProblemCode> {
    let text = message.to_ascii_lowercase();
    if text.is_empty() {
        return None;
    }

    // Order matters: a rate-limit message often also says "limit", and a
    // quota message often carries a 429, so the more specific test runs first.
    let rate_limited = ["rate limit", "too many requests", "retry after"];
    let quota = [
        "usage limit",
        "credit balance",
        "purchase more credits",
        "out of credits",
        "insufficient_quota",
        "quota",
        "billing",
    ];
    let login = [
        "not logged in",
        "please run /login",
        "run `codex login`",
        "unauthorized",
        "invalid_api_key",
        "token has expired",
        "session expired",
        "authentication credentials",
        "please log in",
    ];
    let model = [
        "does not exist or you do not have access",
        "model_not_found",
        "unsupported model",
        "has been retired",
        "unknown model",
    ];

    let matches = |needles: &[&str]| needles.iter().any(|needle| text.contains(needle));

    if matches(&rate_limited) && !matches(&quota) {
        Some(ProblemCode::RateLimited)
    } else if matches(&quota) {
        Some(ProblemCode::QuotaExhausted)
    } else if matches(&login) || contains_status_code(&text, "401") {
        Some(ProblemCode::LoginExpired)
    } else if matches(&model) {
        Some(ProblemCode::ModelUnavailable)
    } else {
        None
    }
}

/// The standing problem, if any, of each provider.
///
/// Cheap to clone-free share: the gateway holds one and every connection reads
/// through it, so two phones see the same answer.
#[derive(Debug, Default)]
pub struct ProblemLog {
    problems: Mutex<HashMap<ProviderId, ProviderProblem>>,
}

impl ProblemLog {
    /// Record a failed turn. Only a message naming a cause we can act on
    /// leaves a standing problem behind.
    pub fn record_turn_failure(&self, provider: ProviderId, payload: &serde_json::Value) {
        let message = failure_message(payload);
        let Some(code) = classify_problem(&message) else {
            return;
        };
        self.problems
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(
                provider,
                ProviderProblem {
                    code,
                    message,
                    observed_at: Utc::now(),
                },
            );
    }

    /// A turn that completed is the only proof that the provider is working
    /// again — a status command can still succeed while turns are refused.
    pub fn record_turn_completed(&self, provider: ProviderId) {
        self.problems
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&provider);
    }

    pub fn problem(&self, provider: ProviderId) -> Option<ProviderProblem> {
        self.problems
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&provider)
            .cloned()
    }
}

/// Whether `text` carries `code` as a standalone number.
///
/// A bare `contains("401")` also matches a timestamp or a byte offset, which
/// would report a healthy account as logged out.
fn contains_status_code(text: &str, code: &str) -> bool {
    text.match_indices(code).any(|(at, _)| {
        let before = text[..at].chars().next_back();
        let after = text[at + code.len()..].chars().next();
        !before.is_some_and(|character| character.is_ascii_digit())
            && !after.is_some_and(|character| character.is_ascii_digit())
    })
}

/// The human-readable part of a turn failure payload, whatever shape it has.
fn failure_message(payload: &serde_json::Value) -> String {
    for key in ["message", "error", "detail", "reason", "stderr"] {
        if let Some(text) = payload.get(key).and_then(serde_json::Value::as_str)
            && !text.trim().is_empty()
        {
            return text.to_owned();
        }
    }
    // Nested one level, which is how both CLIs wrap their own errors.
    for key in ["error", "turn", "failure"] {
        if let Some(nested) = payload.get(key).filter(|value| value.is_object()) {
            let message = failure_message(nested);
            if !message.is_empty() {
                return message;
            }
        }
    }
    String::new()
}
