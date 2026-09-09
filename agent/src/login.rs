//! Signing a provider in from the phone.
//!
//! Both CLIs sign in interactively, and differently: Codex prints a link and a
//! one-time code for you to enter in a browser, Claude sends you to a browser
//! and waits for you to paste a code back. Rather than script either flow —
//! which would break the first time a prompt is reworded — the agent runs the
//! CLI's own login command on a pseudo-terminal, forwards what it prints to
//! the phone, and forwards a line the phone sends back into its input.
//!
//! What is deliberately *not* offered: a way to choose the program or its
//! arguments. A relay that let a phone drive an arbitrary interactive command
//! would be a remote shell. Only `claude auth login` and
//! `codex login --device-auth` can be started here.

use std::io::{Read, Write};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::protocol::ProviderId;

/// How long a login attempt may stay open.
///
/// Codex's device code expires in fifteen minutes; a session still waiting
/// after twenty is one nobody is going to finish, and it holds a child
/// process and a provider's login slot.
const SESSION_LIFETIME: Duration = Duration::from_secs(20 * 60);

/// Cap on the transcript kept for one login attempt. The flows are a screen
/// or two of text; anything beyond this is a CLI in a loop.
const MAX_TRANSCRIPT: usize = 64 * 1024;

/// What the phone is shown while a login is in progress.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginProgress {
    /// The channel a phone watches for this flow, `login:<provider>`. Login
    /// belongs to no conversation, but every event on the wire is addressed
    /// to one, so it gets a stable name of its own rather than landing in
    /// whichever conversation happened to be open.
    pub conversation_id: String,
    pub session_id: String,
    pub provider: ProviderId,
    /// Everything the CLI has printed so far, with terminal control codes
    /// removed. Sent whole rather than as deltas: it is small, and a phone
    /// that reconnects mid-login then needs no replay.
    pub output: String,
    /// The link to open, when the CLI has printed one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verification_url: Option<String>,
    /// The code to enter at that link, when the CLI has printed one. Codex's
    /// flow shows a code; Claude's asks for one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_code: Option<String>,
    /// Whether the CLI is waiting for the phone to send something.
    pub awaiting_input: bool,
}

/// How a login attempt ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginOutcome {
    pub conversation_id: String,
    pub session_id: String,
    pub provider: ProviderId,
    pub succeeded: bool,
    /// Why it did not, in the CLI's own words where there are any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// Remove terminal control sequences so the phone shows text, not escapes.
///
/// Both CLIs colour their output and Codex redraws lines; forwarding the raw
/// bytes would put `[94m` in the middle of the code someone has to read.
pub fn strip_terminal_codes(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(character) = chars.next() {
        match character {
            '\u{1b}' => {
                // CSI (ESC [ … final byte) and OSC (ESC ] … BEL/ST).
                match chars.peek() {
                    Some('[') => {
                        chars.next();
                        for inner in chars.by_ref() {
                            if inner.is_ascii_alphabetic() || inner == '~' {
                                break;
                            }
                        }
                    }
                    Some(']') => {
                        chars.next();
                        while let Some(inner) = chars.next() {
                            if inner == '\u{7}' {
                                break;
                            }
                            if inner == '\u{1b}' && chars.peek() == Some(&'\\') {
                                chars.next();
                                break;
                            }
                        }
                    }
                    // A lone escape, or a two-character sequence.
                    _ => {
                        chars.next();
                    }
                }
            }
            '\r' => {
                // A carriage return is a redraw of the current line, not a
                // new line. Dropping the line it overwrites keeps spinners
                // from filling the phone's view.
                if chars.peek() == Some(&'\n') {
                    continue;
                }
                while !out.is_empty() && !out.ends_with('\n') {
                    out.pop();
                }
            }
            '\u{8}' => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

/// The link a login flow wants opened, if it has printed one.
pub fn find_verification_url(text: &str) -> Option<String> {
    text.split_whitespace()
        .map(|word| word.trim_matches(|character: char| "(),.<>\"'`".contains(character)))
        .find(|word| word.starts_with("https://"))
        .map(str::to_owned)
}

/// The one-time code a login flow has printed, if it has printed one.
///
/// Codex's is two groups of characters joined by a hyphen, on a line of its
/// own. Matching that shape rather than the sentence around it keeps this
/// working when the wording changes.
pub fn find_user_code(text: &str) -> Option<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| (7..=16).contains(&line.chars().count()))
        .find(|line| {
            let mut groups = line.split('-');
            let first = groups.next().unwrap_or_default();
            let second = groups.next().unwrap_or_default();
            groups.next().is_none()
                && first.len() >= 3
                && second.len() >= 3
                && line.chars().all(|character| {
                    character.is_ascii_uppercase() || character.is_ascii_digit() || character == '-'
                })
        })
        .map(str::to_owned)
}

/// Whether the CLI is sitting at a prompt waiting for something to be typed.
pub fn looks_like_a_prompt(text: &str) -> bool {
    let tail = text
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or_default()
        .trim_end()
        .to_ascii_lowercase();
    tail.ends_with(':')
        || tail.ends_with('?')
        || tail.ends_with('>')
        || tail.contains("paste")
        || tail.contains("enter the code")
        // Claude stops on an organisation's managed-settings confirmation,
        // whose last line offers a keypress rather than a field.
        || tail.contains("enter to confirm")
}

/// The login command for one provider. Fixed, so this relay can never be
/// pointed at another program.
fn login_command(provider: ProviderId, program: &str) -> (String, Vec<String>) {
    match provider {
        ProviderId::Claude => (program.to_owned(), vec!["auth".into(), "login".into()]),
        // The device-code flow is the only one that works without a browser
        // on this Mac being the one the person is holding.
        ProviderId::Codex => (
            program.to_owned(),
            vec!["login".into(), "--device-auth".into()],
        ),
    }
}

/// The logout command for one provider.
pub fn logout_command(provider: ProviderId, program: &str) -> (String, Vec<String>) {
    match provider {
        ProviderId::Claude => (program.to_owned(), vec!["auth".into(), "logout".into()]),
        ProviderId::Codex => (program.to_owned(), vec!["logout".into()]),
    }
}

/// One login attempt in progress.
pub struct LoginSession {
    pub id: String,
    pub provider: ProviderId,
    /// Where the credential should be filed if this succeeds.
    pub label: Option<String>,
    transcript: Arc<Mutex<String>>,
    /// False once the child has exited. A session that has ended must not be
    /// handed to the next request as though it were running: the phone would
    /// be shown its empty transcript for ever, with no process behind it and
    /// nothing able to answer.
    running: Arc<std::sync::atomic::AtomicBool>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    /// A handle that can signal the child while another thread sits in
    /// `wait`. Holding the child itself behind a mutex would deadlock
    /// cancellation against the thread waiting for it to exit — which is
    /// exactly what cancelling has to interrupt.
    killer: Arc<Mutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>>,
}

impl LoginSession {
    /// Start the provider's own login command on a pseudo-terminal.
    ///
    /// `on_output` is called whenever the CLI prints; `on_exit` once, when it
    /// finishes. Both run on their own threads, and `on_exit` can run before
    /// this function has returned — a login command that fails immediately
    /// does — which is why the caller supplies the id rather than reading it
    /// back off the returned session.
    pub fn start(
        id: impl Into<String>,
        provider: ProviderId,
        program: &str,
        label: Option<String>,
        on_output: impl Fn(LoginProgress) + Send + 'static,
        on_exit: impl FnOnce(bool, String) + Send + 'static,
    ) -> anyhow::Result<Self> {
        let (program, args) = login_command(provider, program);
        let pty = portable_pty::native_pty_system();
        let pair = pty.openpty(portable_pty::PtySize {
            rows: 40,
            cols: 100,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        let mut command = portable_pty::CommandBuilder::new(&program);
        for argument in &args {
            command.arg(argument);
        }
        // A CLI that thinks it is on a dumb terminal draws no spinners.
        command.env("TERM", "dumb");
        command.env("NO_COLOR", "1");
        let mut child = pair.slave.spawn_command(command)?;
        let killer = child.clone_killer();
        drop(pair.slave);

        let id = id.into();
        let transcript = Arc::new(Mutex::new(String::new()));
        let running = Arc::new(std::sync::atomic::AtomicBool::new(true));
        let writer = Arc::new(Mutex::new(pair.master.take_writer()?));
        let mut reader = pair.master.try_clone_reader()?;

        {
            let id = id.clone();
            let transcript = transcript.clone();
            std::thread::spawn(move || {
                let mut buffer = [0u8; 4096];
                loop {
                    match reader.read(&mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(read) => {
                            let chunk = String::from_utf8_lossy(&buffer[..read]).into_owned();
                            let mut held =
                                transcript.lock().unwrap_or_else(PoisonError::into_inner);
                            held.push_str(&strip_terminal_codes(&chunk));
                            if held.len() > MAX_TRANSCRIPT {
                                let cut = held.len() - MAX_TRANSCRIPT;
                                *held = held[cut..].to_owned();
                            }
                            on_output(progress(&id, provider, &held));
                        }
                    }
                }
            });
        }

        {
            let transcript = transcript.clone();
            let running = running.clone();
            std::thread::spawn(move || {
                let status = child.wait().map(|status| status.success()).unwrap_or(false);
                running.store(false, std::sync::atomic::Ordering::SeqCst);
                let tail = transcript
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                on_exit(status, tail);
            });
        }

        Ok(Self {
            id,
            provider,
            label,
            transcript,
            running,
            writer,
            killer: Arc::new(Mutex::new(killer)),
        })
    }

    /// Whether the child is still running.
    pub fn is_running(&self) -> bool {
        self.running.load(std::sync::atomic::Ordering::SeqCst)
    }

    pub fn progress(&self) -> LoginProgress {
        let held = self
            .transcript
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        progress(&self.id, self.provider, &held)
    }

    /// Send one line to the CLI's input — the verification code, or an answer
    /// to a prompt.
    pub fn send_line(&self, line: &str) -> anyhow::Result<()> {
        anyhow::ensure!(line.len() <= 512, "that is too long to be a code");
        anyhow::ensure!(
            !line.contains('\n') && !line.contains('\r'),
            "one line at a time"
        );
        let mut writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
        writer.write_all(line.as_bytes())?;
        writer.write_all(b"\r")?;
        writer.flush()?;
        Ok(())
    }

    pub fn cancel(&self) {
        self.running
            .store(false, std::sync::atomic::Ordering::SeqCst);
        let _ = self
            .killer
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .kill();
    }

    pub fn lifetime() -> Duration {
        SESSION_LIFETIME
    }
}

/// The channel name for one provider's login flow.
pub fn login_channel(provider: ProviderId) -> String {
    format!("login:{}", crate::credentials::provider_slug(provider))
}

fn progress(id: &str, provider: ProviderId, transcript: &str) -> LoginProgress {
    LoginProgress {
        conversation_id: login_channel(provider),
        session_id: id.to_owned(),
        provider,
        output: transcript.to_owned(),
        verification_url: find_verification_url(transcript),
        user_code: find_user_code(transcript),
        awaiting_input: looks_like_a_prompt(transcript),
    }
}
