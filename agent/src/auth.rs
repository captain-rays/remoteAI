//! Which account each provider's CLI is currently signed in as.
//!
//! Both CLIs answer this themselves — `claude auth status --json` and
//! `codex login status` — so the agent asks them rather than reading their
//! credential stores. Parsing is separated from spawning so each CLI's exact
//! wording is pinned by a test.

use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tokio::sync::Mutex;

/// Whether a provider is signed in.
///
/// `Unknown` is a real answer and not a synonym for `LoggedOut`: a CLI that
/// crashed, is missing, or printed something new tells us nothing about the
/// credential, and sending someone to re-authenticate on that basis wastes
/// their time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LoginState {
    LoggedIn,
    LoggedOut,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderLogin {
    pub state: LoginState,
    /// How the person would recognise this account: an email where there is
    /// one, otherwise the sign-in method.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    /// Anything else worth showing next to it — organisation, plan.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl ProviderLogin {
    pub fn unknown() -> Self {
        Self {
            state: LoginState::Unknown,
            account: None,
            detail: None,
        }
    }

    fn logged_out() -> Self {
        Self {
            state: LoginState::LoggedOut,
            account: None,
            detail: None,
        }
    }
}

/// Parse `claude auth status --json`.
pub fn parse_claude_auth_status(output: &str) -> ProviderLogin {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(output.trim()) else {
        return ProviderLogin::unknown();
    };
    let Some(logged_in) = value.get("loggedIn").and_then(serde_json::Value::as_bool) else {
        return ProviderLogin::unknown();
    };
    if !logged_in {
        return ProviderLogin::logged_out();
    }
    let text = |key: &str| {
        value
            .get(key)
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
    };
    let account = text("email").or_else(|| text("authMethod"));
    let detail = match (text("orgName"), text("subscriptionType")) {
        (Some(org), Some(plan)) => Some(format!("{org} · {plan}")),
        (Some(org), None) => Some(org),
        (None, Some(plan)) => Some(plan),
        (None, None) => None,
    };
    ProviderLogin {
        state: LoginState::LoggedIn,
        account,
        detail,
    }
}

/// Parse `codex login status`, which answers in one line of prose.
pub fn parse_codex_login_status(output: &str) -> ProviderLogin {
    let line = output
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default();
    let lowercase = line.to_ascii_lowercase();
    if lowercase.starts_with("not logged in") {
        return ProviderLogin::logged_out();
    }
    // "Logged in using ChatGPT", "Logged in using an API key".
    if let Some(method) = lowercase
        .strip_prefix("logged in using ")
        .map(|method| line[line.len() - method.len()..].to_owned())
    {
        return ProviderLogin {
            state: LoginState::LoggedIn,
            account: Some(method),
            detail: None,
        };
    }
    if lowercase.starts_with("logged in") {
        return ProviderLogin {
            state: LoginState::LoggedIn,
            account: None,
            detail: None,
        };
    }
    ProviderLogin::unknown()
}

/// How long a login answer is reused before the CLI is asked again.
///
/// Each answer costs a process spawn, and the phone asks for provider status
/// on every catalog reload. A minute is short enough that a login done on the
/// Mac shows up on the phone promptly, and long enough that scrolling the app
/// does not spawn two CLIs a second.
const CACHE_FOR: Duration = Duration::from_secs(60);

/// How long the CLI gets to answer. `claude` in particular is a Node program
/// with a slow start, but a status command that has not answered in this long
/// is hung, and the phone is waiting on it.
const PROBE_TIMEOUT: Duration = Duration::from_secs(20);

/// Asks one provider's CLI who is logged in, and remembers the answer briefly.
#[derive(Debug)]
pub struct LoginProbe {
    program: String,
    args: Vec<String>,
    parse: fn(&str) -> ProviderLogin,
    cached: Arc<Mutex<Option<(Instant, ProviderLogin)>>>,
    cache_for: Duration,
}

impl LoginProbe {
    pub fn claude(program: impl Into<String>) -> Self {
        Self::new(
            program,
            ["auth", "status", "--json"],
            parse_claude_auth_status,
        )
    }

    pub fn codex(program: impl Into<String>) -> Self {
        Self::new(program, ["login", "status"], parse_codex_login_status)
    }

    fn new<const N: usize>(
        program: impl Into<String>,
        args: [&str; N],
        parse: fn(&str) -> ProviderLogin,
    ) -> Self {
        Self {
            program: program.into(),
            args: args.iter().map(|argument| (*argument).to_owned()).collect(),
            parse,
            cached: Arc::new(Mutex::new(None)),
            cache_for: CACHE_FOR,
        }
    }

    /// Change how long an answer is reused.
    ///
    /// Production keeps the default: the phone asks for provider status on
    /// every catalog reload, and each answer costs a process spawn. A test
    /// that changes a credential behind the CLI's back sets this to zero, so
    /// what it is checking is the logic and not the clock.
    pub fn with_cache_for(mut self, cache_for: Duration) -> Self {
        self.cache_for = cache_for;
        self
    }

    /// Drop the remembered answer, so the next read asks the CLI again. Called
    /// after anything that changes the credential.
    pub async fn forget(&self) {
        *self.cached.lock().await = None;
    }

    pub async fn read(&self) -> ProviderLogin {
        let mut cached = self.cached.lock().await;
        if let Some((measured_at, login)) = cached.as_ref()
            && measured_at.elapsed() < self.cache_for
        {
            return login.clone();
        }
        let login = self.spawn().await;
        // An answer we could not obtain is not cached: the next read should
        // try again rather than repeat "unknown" for a minute.
        if login.state != LoginState::Unknown {
            *cached = Some((Instant::now(), login.clone()));
        }
        login
    }

    async fn spawn(&self) -> ProviderLogin {
        let child = Command::new(&self.program)
            .args(&self.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .output();
        match tokio::time::timeout(PROBE_TIMEOUT, child).await {
            Ok(Ok(output)) => {
                let text = String::from_utf8_lossy(&output.stdout);
                let login = (self.parse)(&text);
                if login.state == LoginState::Unknown {
                    // Some CLIs report "not logged in" on stderr and exit
                    // non-zero, which is an answer, not a malfunction.
                    let error = String::from_utf8_lossy(&output.stderr);
                    return (self.parse)(&error);
                }
                login
            }
            Ok(Err(_)) | Err(_) => ProviderLogin::unknown(),
        }
    }
}
