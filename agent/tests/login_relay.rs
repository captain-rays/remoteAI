//! Reading a login flow's output well enough to drive it from a phone.
//!
//! The wording of these flows is not ours and will change. Everything here
//! matches shape rather than sentences, and the fixtures are the real output
//! the CLIs produced.

use remote_ai_agent::login::{
    LoginSession, find_user_code, find_verification_url, logout_command, looks_like_a_prompt,
    strip_terminal_codes,
};
use remote_ai_agent::protocol::ProviderId;

/// What `codex login --device-auth` actually printed, escape codes included.
const CODEX_DEVICE_AUTH: &str = concat!(
    "\n\u{1b}[1mWelcome to Codex\u{1b}[0m [\u{1b}[90m0.144.4\u{1b}[0m]\n",
    "\u{1b}[90mOpenAI's command-line coding agent\u{1b}[0m\n\n",
    "Follow these steps to sign in with ChatGPT using device code authorization:\n\n",
    "1. Open this link in your browser and sign in to your account\n",
    "   \u{1b}[94mhttps://auth.openai.com/codex/device\u{1b}[0m\n\n",
    "2. Enter this one-time code \u{1b}[90m(expires in 15 minutes)\u{1b}[0m\n",
    "   \u{1b}[94mZ28N-596S1\u{1b}[0m\n\n",
    "\u{1b}[90mContinue only if you started this login in Codex.\u{1b}[0m\n",
);

#[test]
fn terminal_colour_codes_do_not_reach_the_phone() {
    let clean = strip_terminal_codes(CODEX_DEVICE_AUTH);
    assert!(!clean.contains('\u{1b}'), "an escape survived: {clean:?}");
    assert!(!clean.contains("[94m"));
    assert!(clean.contains("Welcome to Codex"));
    assert!(clean.contains("Z28N-596S1"));
}

#[test]
fn a_redrawn_line_replaces_the_one_it_overwrites() {
    // A spinner is a carriage return and a rewrite. Kept literally, the
    // phone would show every frame of it.
    let spun = strip_terminal_codes("Waiting.\rWaiting..\rWaiting...\rDone\n");
    assert_eq!(spun, "Done\n");
    // A CRLF is an ordinary line ending and must survive as one.
    assert_eq!(strip_terminal_codes("one\r\ntwo\r\n"), "one\ntwo\n");
}

#[test]
fn the_link_and_the_code_are_pulled_out_for_the_phone_to_show() {
    let clean = strip_terminal_codes(CODEX_DEVICE_AUTH);
    assert_eq!(
        find_verification_url(&clean).as_deref(),
        Some("https://auth.openai.com/codex/device")
    );
    assert_eq!(find_user_code(&clean).as_deref(), Some("Z28N-596S1"));
}

#[test]
fn output_with_no_link_or_code_yields_neither() {
    // Half of a login flow is prose. Inventing a code from it would put a
    // wrong one in front of the reader.
    let text = "Opening your browser to sign in to your Anthropic account.\n";
    assert_eq!(find_verification_url(text), None);
    assert_eq!(find_user_code(text), None);
}

#[test]
fn a_version_number_is_not_mistaken_for_a_verification_code() {
    for text in ["0.144.4\n", "2026-09-07\n", "gpt-5.6-sol\n", "abc\n"] {
        assert_eq!(find_user_code(text), None, "{text:?}");
    }
}

#[test]
fn a_trailing_prompt_is_recognised_as_waiting_for_the_phone() {
    assert!(looks_like_a_prompt("Paste the code here: "));
    assert!(looks_like_a_prompt("Enter the code you were given:"));
    assert!(looks_like_a_prompt("Continue? "));
    assert!(!looks_like_a_prompt(
        "Follow these steps to sign in with ChatGPT.\n"
    ));
}

#[test]
fn the_relay_can_only_run_each_cli_login_and_logout() {
    // The point of a fixed command table: a phone chooses a provider, never
    // a program or an argument.
    assert_eq!(
        logout_command(ProviderId::Claude, "/usr/local/bin/claude"),
        ("/usr/local/bin/claude".to_owned(), vec!["auth".to_owned(), "logout".to_owned()])
    );
    assert_eq!(
        logout_command(ProviderId::Codex, "/opt/homebrew/bin/codex"),
        ("/opt/homebrew/bin/codex".to_owned(), vec!["logout".to_owned()])
    );
}

#[tokio::test]
async fn a_login_session_forwards_output_and_input_over_a_terminal() {
    // Driven against a stand-in that behaves like the real flows: prints a
    // prompt, waits for a line, reports what it got. It exercises the pty,
    // the reader thread, the writer and the exit hook — everything except
    // which program is spawned.
    let script = tempfile::Builder::new()
        .prefix("login-stub")
        .suffix(".sh")
        .tempfile()
        .unwrap();
    std::fs::write(
        script.path(),
        "#!/bin/sh\n\
         printf 'Open this link in your browser\\n'\n\
         printf 'https://auth.example.com/device\\n'\n\
         printf 'ABCD-12345\\n'\n\
         printf 'Paste the code here: '\n\
         read answer\n\
         printf '\\ngot [%s]\\n' \"$answer\"\n\
         test \"$answer\" = 'TYPED-CODE'\n",
    )
    .unwrap();
    std::fs::set_permissions(
        script.path(),
        <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o700),
    )
    .unwrap();

    let progress = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();
    let session = {
        let progress = progress.clone();
        LoginSession::start(
            "session-1",
            // Claude's command shape is `<program> auth login`; the stub
            // ignores its arguments, so either provider exercises the relay.
            ProviderId::Claude,
            script.path().to_str().unwrap(),
            Some("work".to_owned()),
            move |update| {
                progress
                    .lock()
                    .unwrap()
                    .push(update);
            },
            move |succeeded, tail| {
                let _ = finished_tx.send((succeeded, tail));
            },
        )
        .unwrap()
    };

    // Wait for the prompt rather than for a guessed interval.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let current = session.progress();
        if current.awaiting_input && current.user_code.is_some() {
            assert_eq!(
                current.verification_url.as_deref(),
                Some("https://auth.example.com/device")
            );
            assert_eq!(current.user_code.as_deref(), Some("ABCD-12345"));
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "no prompt arrived; saw {:?}",
            current.output
        );
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }

    session.send_line("TYPED-CODE").unwrap();

    let (succeeded, tail) = finished_rx
        .recv_timeout(std::time::Duration::from_secs(10))
        .expect("the login stub exited");
    assert!(succeeded, "the code reached the CLI: {tail:?}");
    assert!(tail.contains("got [TYPED-CODE]"), "{tail:?}");
    assert!(
        !progress.lock().unwrap().is_empty(),
        "the phone was kept up to date while it ran"
    );
}

#[tokio::test]
async fn a_multiline_input_is_refused_rather_than_typed() {
    // The phone sends one line. Accepting embedded newlines would let it
    // answer prompts it has not seen yet.
    let script = tempfile::Builder::new().suffix(".sh").tempfile().unwrap();
    std::fs::write(script.path(), "#!/bin/sh\nread answer\n").unwrap();
    std::fs::set_permissions(
        script.path(),
        <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o700),
    )
    .unwrap();

    let session = LoginSession::start(
        "session-2",
        ProviderId::Claude,
        script.path().to_str().unwrap(),
        None,
        |_| {},
        |_, _| {},
    )
    .unwrap();

    assert!(session.send_line("code\nyes").is_err());
    assert!(session.send_line(&"x".repeat(513)).is_err());
    session.cancel();
}

#[tokio::test]
async fn cancelling_a_login_that_is_waiting_returns_at_once() {
    // The thread watching for the child to exit is blocked in `wait` for as
    // long as the flow is open. Cancelling must not queue behind it: with the
    // child held behind the same lock, this call never returned, and a
    // cancelled login on the phone hung the whole request.
    let script = tempfile::Builder::new().suffix(".sh").tempfile().unwrap();
    std::fs::write(script.path(), "#!/bin/sh\nread answer\n").unwrap();
    std::fs::set_permissions(
        script.path(),
        <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o700),
    )
    .unwrap();

    let (exited_tx, exited_rx) = std::sync::mpsc::channel();
    let session = LoginSession::start(
        "session-3",
        ProviderId::Codex,
        script.path().to_str().unwrap(),
        None,
        |_| {},
        move |succeeded, _| {
            let _ = exited_tx.send(succeeded);
        },
    )
    .unwrap();

    let cancelled = tokio::task::spawn_blocking(move || {
        let started = std::time::Instant::now();
        session.cancel();
        started.elapsed()
    });
    let took = tokio::time::timeout(std::time::Duration::from_secs(5), cancelled)
        .await
        .expect("cancel must not block")
        .unwrap();
    assert!(took < std::time::Duration::from_secs(2), "cancel took {took:?}");

    assert_eq!(
        exited_rx.recv_timeout(std::time::Duration::from_secs(5)),
        Ok(false),
        "a killed login reports failure rather than nothing"
    );
}
