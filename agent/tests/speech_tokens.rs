//! Handing the phone a short-lived speech token.
//!
//! The account key that mints these stays on this Mac, in the login keychain.
//! The phone gets a token that expires, so a lost phone cannot keep using the
//! account, and it talks to the speech service directly — the audio never
//! passes through here.

use std::sync::{Arc, Mutex};

use chrono::{Duration, Utc};
use remote_ai_agent::credentials::InMemorySecrets;
use remote_ai_agent::speech::{
    CreateTokenResponse, SpeechError, SpeechTokens, canonical_query, sign_request,
    string_to_sign,
};

fn secrets(id: &str, secret: &str) -> InMemorySecrets {
    let store = InMemorySecrets::default();
    use remote_ai_agent::credentials::SecretStore;
    store.put("aliyun.nls", "access-key-id", id.as_bytes()).unwrap();
    store
        .put("aliyun.nls", "access-key-secret", secret.as_bytes())
        .unwrap();
    store
}

#[test]
fn the_query_is_canonicalised_the_way_the_service_expects() {
    // Sorted by key, and percent-encoded with the service's own rules: `~`
    // stays, a space is %20 rather than +, and `/` becomes %2F. Getting any
    // of these wrong produces a signature the service rejects, with an error
    // that names none of them.
    let canonical = canonical_query(&[
        ("Version", "2019-02-28"),
        ("Action", "CreateToken"),
        ("Odd", "a b/c~d"),
    ]);
    assert_eq!(
        canonical,
        "Action=CreateToken&Odd=a%20b%2Fc~d&Version=2019-02-28"
    );
}

#[test]
fn the_string_to_sign_carries_the_method_and_the_escaped_query() {
    assert_eq!(
        string_to_sign("POST", "Action=CreateToken&Version=2019-02-28"),
        "POST&%2F&Action%3DCreateToken%26Version%3D2019-02-28"
    );
}

#[test]
fn the_signature_is_hmac_sha1_over_that_string_with_an_appended_ampersand() {
    // The trailing `&` on the secret is part of Alibaba Cloud's scheme, not a
    // typo; without it every request is rejected as unsigned.
    let signature = sign_request("test-secret", "POST&%2F&Action%3DCreateToken");
    assert_eq!(signature, "oqRd3AVyosK9bJwwOoSBpLgK8gY=");
}

#[test]
fn a_minted_token_is_reused_until_it_is_nearly_expired() {
    // Each mint is a signed round trip to the service. Doing one per phone
    // request would be slow and pointless: the token lasts for days.
    let mints = Arc::new(Mutex::new(0));
    let counted = mints.clone();
    let tokens = SpeechTokens::new(
        "an-appkey",
        Box::new(secrets("LTAI-id", "a-secret")),
        move |_| {
            *counted.lock().unwrap() += 1;
            Ok(CreateTokenResponse {
                id: "token-1".into(),
                expires_at: Utc::now() + Duration::hours(24),
            })
        },
    );

    let first = tokens.credentials().expect("a token");
    let second = tokens.credentials().expect("the same token");

    assert_eq!(first.token, "token-1");
    assert_eq!(second.token, "token-1");
    assert_eq!(*mints.lock().unwrap(), 1, "one mint, not two");
    assert_eq!(first.appkey, "an-appkey");
    assert!(first.endpoint.starts_with("wss://"), "{}", first.endpoint);
}

#[test]
fn a_token_close_to_expiry_is_replaced_rather_than_handed_out() {
    // A token with a minute left would expire mid-sentence. The margin is
    // what stops the phone being handed one.
    let mints = Arc::new(Mutex::new(0));
    let counted = mints.clone();
    let tokens = SpeechTokens::new(
        "an-appkey",
        Box::new(secrets("LTAI-id", "a-secret")),
        move |_| {
            let n = {
                let mut held = counted.lock().unwrap();
                *held += 1;
                *held
            };
            Ok(CreateTokenResponse {
                id: format!("token-{n}"),
                // The first one is already inside the margin.
                expires_at: Utc::now()
                    + if n == 1 { Duration::seconds(30) } else { Duration::hours(24) },
            })
        },
    );

    assert_eq!(tokens.credentials().unwrap().token, "token-1");
    assert_eq!(
        tokens.credentials().unwrap().token,
        "token-2",
        "a token about to expire is not reused"
    );
}

#[test]
fn a_mac_with_no_account_key_says_so_instead_of_failing_obscurely() {
    let tokens = SpeechTokens::new(
        "an-appkey",
        Box::new(InMemorySecrets::default()),
        |_| panic!("must not reach the service without a key"),
    );
    assert_eq!(tokens.credentials(), Err(SpeechError::NoAccountKey));
}

#[test]
fn speech_with_no_appkey_configured_is_reported_as_unconfigured() {
    let tokens = SpeechTokens::new(
        "",
        Box::new(secrets("LTAI-id", "a-secret")),
        |_| panic!("must not reach the service without an appkey"),
    );
    assert_eq!(tokens.credentials(), Err(SpeechError::NotConfigured));
}

#[test]
fn the_services_own_response_shape_is_understood() {
    // Pinned against a real reply: the token and its expiry live under a
    // `Token` object, and the expiry is a Unix timestamp in seconds.
    let parsed = remote_ai_agent::speech::parse_create_token(
        r#"{"NlsRequestId":"x","RequestId":"y","Token":
            {"UserId":"1","Id":"2c142ed2","ExpireTime":1757469047}}"#,
    )
    .expect("a token");
    assert_eq!(parsed.id, "2c142ed2");
    assert_eq!(parsed.expires_at.timestamp(), 1_757_469_047);
}

#[test]
fn an_error_reply_is_reported_with_the_services_code() {
    // What a wrong key actually produces. The code is the part worth
    // repeating; it is the difference between "fix your key" and "retry".
    let error = remote_ai_agent::speech::parse_create_token(
        r#"{"RequestId":"x","Message":"Specified access key is not found.",
            "Code":"InvalidAccessKeyId.NotFound"}"#,
    )
    .expect_err("not a token");
    assert_eq!(error, SpeechError::Rejected("InvalidAccessKeyId.NotFound".into()));
}

/// The production path: the key in this Mac's keychain, a real signed request,
/// a real token. Ignored by default because it needs that key and the network.
///
///     cargo test --test speech_tokens -- --ignored
#[test]
#[ignore = "uses this Mac's speech account key and reaches the service"]
fn this_macs_own_key_mints_a_usable_token() {
    let appkey = std::env::var("REMOTEAI_ALIYUN_APPKEY").unwrap_or_default();
    if appkey.is_empty() {
        eprintln!("REMOTEAI_ALIYUN_APPKEY is not set; nothing to check");
        return;
    }
    let tokens = SpeechTokens::from_keychain(appkey.clone());
    let credentials = tokens.credentials().expect("a token");

    assert_eq!(credentials.appkey, appkey);
    assert!(!credentials.token.is_empty());
    assert!(
        credentials.expires_at > Utc::now() + Duration::hours(1),
        "a token good for less than an hour is not worth handing out: {}",
        credentials.expires_at
    );
    assert_eq!(
        credentials.endpoint,
        "wss://nls-gateway-cn-shanghai.aliyuncs.com/ws/v1"
    );
    // The value itself is never printed.
    println!(
        "minted a token of {} characters, good until {}",
        credentials.token.len(),
        credentials.expires_at
    );
}
