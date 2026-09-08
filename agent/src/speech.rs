//! A short-lived speech token for the phone.
//!
//! Speech recognition happens between the phone and the speech service
//! directly: audio never passes through this agent, which would add a hop
//! through the tunnel to every syllable. What the agent contributes is the one
//! thing the phone must not hold — the account key that mints tokens. That key
//! stays in this Mac's login keychain; the phone gets a token that expires.
//!
//! The request is signed here rather than delegated to a cloud SDK, because
//! pulling one in for a single signed POST would cost more than the twenty
//! lines the signature actually takes.

use std::process::Stdio;
use std::sync::{Mutex, PoisonError};

use chrono::{DateTime, TimeZone, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha1::Sha1;

use crate::credentials::SecretStore;

/// The keychain service the account key is kept under.
pub const KEYCHAIN_SERVICE: &str = "aliyun.nls";

/// Where the phone streams audio. Fixed: the token is region-scoped, so the
/// endpoint is not the phone's to choose.
const ENDPOINT: &str = "wss://nls-gateway-cn-shanghai.aliyuncs.com/ws/v1";

/// Where tokens are minted.
const TOKEN_HOST: &str = "https://nls-meta.cn-shanghai.aliyuncs.com/";

/// How much life a token must have left to be worth handing out. A token with
/// a minute on it would expire mid-sentence.
const MARGIN: chrono::TimeDelta = chrono::TimeDelta::minutes(5);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeechCredentials {
    /// Identifies the speech project. Not a secret, but not ours to publish.
    pub appkey: String,
    pub token: String,
    pub expires_at: DateTime<Utc>,
    pub endpoint: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SpeechError {
    #[error("speech is not configured on this Mac")]
    NotConfigured,
    #[error("no speech account key is in this Mac's keychain")]
    NoAccountKey,
    #[error("the speech service refused the request: {0}")]
    Rejected(String),
    #[error("the speech service could not be reached")]
    Unreachable,
}

impl SpeechError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotConfigured => "speech_not_configured",
            Self::NoAccountKey => "speech_no_account_key",
            Self::Rejected(_) => "speech_rejected",
            Self::Unreachable => "speech_unreachable",
        }
    }
}

/// What the mint step returns, separated from how it is fetched so tests can
/// supply one without a network.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateTokenResponse {
    pub id: String,
    pub expires_at: DateTime<Utc>,
}

type Mint = Box<dyn Fn(&str) -> Result<CreateTokenResponse, SpeechError> + Send + Sync>;

pub struct SpeechTokens {
    appkey: String,
    secrets: Box<dyn SecretStore>,
    mint: Mint,
    cached: Mutex<Option<SpeechCredentials>>,
}

impl SpeechTokens {
    pub fn new(
        appkey: impl Into<String>,
        secrets: Box<dyn SecretStore>,
        mint: impl Fn(&str) -> Result<CreateTokenResponse, SpeechError> + Send + Sync + 'static,
    ) -> Self {
        Self {
            appkey: appkey.into(),
            secrets,
            mint: Box::new(mint),
            cached: Mutex::new(None),
        }
    }

    /// The production wiring: sign with the key in the login keychain and post
    /// the request with `curl`.
    pub fn from_keychain(appkey: impl Into<String>) -> Self {
        Self::new(
            appkey,
            Box::new(crate::credentials::Keychain),
            post_create_token,
        )
    }

    pub fn credentials(&self) -> Result<SpeechCredentials, SpeechError> {
        if self.appkey.is_empty() {
            return Err(SpeechError::NotConfigured);
        }
        let mut cached = self.cached.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(held) = cached.as_ref()
            && held.expires_at - Utc::now() > MARGIN
        {
            return Ok(held.clone());
        }

        let key_id = self.stored("access-key-id")?;
        let key_secret = self.stored("access-key-secret")?;
        let minted = (self.mint)(&signed_create_token_body(&key_id, &key_secret))?;
        let fresh = SpeechCredentials {
            appkey: self.appkey.clone(),
            token: minted.id,
            expires_at: minted.expires_at,
            endpoint: ENDPOINT.to_owned(),
        };
        *cached = Some(fresh.clone());
        Ok(fresh)
    }

    fn stored(&self, account: &str) -> Result<String, SpeechError> {
        let raw = self
            .secrets
            .get(KEYCHAIN_SERVICE, account)
            .map_err(|_| SpeechError::NoAccountKey)?
            .ok_or(SpeechError::NoAccountKey)?;
        let value = String::from_utf8(raw)
            .map_err(|_| SpeechError::NoAccountKey)?
            .trim()
            .to_owned();
        if value.is_empty() {
            return Err(SpeechError::NoAccountKey);
        }
        Ok(value)
    }
}

/// Percent-encode one value the way the service's signature expects.
///
/// Not the same as ordinary URL encoding: a space is `%20` and not `+`, and
/// `~` is left alone. Both differences produce a rejected signature, with an
/// error that mentions neither.
fn encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

/// The request's parameters, sorted by key and encoded.
pub fn canonical_query(params: &[(&str, &str)]) -> String {
    let mut sorted: Vec<_> = params.to_vec();
    sorted.sort_by(|left, right| left.0.cmp(right.0));
    sorted
        .iter()
        .map(|(key, value)| format!("{}={}", encode(key), encode(value)))
        .collect::<Vec<_>>()
        .join("&")
}

pub fn string_to_sign(method: &str, canonical: &str) -> String {
    format!("{method}&{}&{}", encode("/"), encode(canonical))
}

/// HMAC-SHA1, keyed with the secret plus a trailing `&` — part of the scheme,
/// not a typo.
pub fn sign_request(secret: &str, string_to_sign: &str) -> String {
    let mut mac = Hmac::<Sha1>::new_from_slice(format!("{secret}&").as_bytes())
        .expect("hmac accepts any key length");
    mac.update(string_to_sign.as_bytes());
    base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        mac.finalize().into_bytes(),
    )
}

/// The full signed request body for `CreateToken`.
fn signed_create_token_body(key_id: &str, key_secret: &str) -> String {
    let timestamp = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let nonce = uuid::Uuid::new_v4().to_string();
    let params = [
        ("AccessKeyId", key_id),
        ("Action", "CreateToken"),
        ("Format", "JSON"),
        ("RegionId", "cn-shanghai"),
        ("SignatureMethod", "HMAC-SHA1"),
        ("SignatureNonce", nonce.as_str()),
        ("SignatureVersion", "1.0"),
        ("Timestamp", timestamp.as_str()),
        ("Version", "2019-02-28"),
    ];
    let canonical = canonical_query(&params);
    let signature = sign_request(key_secret, &string_to_sign("POST", &canonical));
    format!("Signature={}&{canonical}", encode(&signature))
}

/// Post the signed body with `curl`, feeding it through a config on stdin.
///
/// Nothing sensitive reaches the command line: `ps` shows only `curl -K -`.
/// The alternative — a Rust HTTP client with TLS — would add some fifty crates
/// for one request, in a process that already spawns programs for a living.
fn post_create_token(body: &str) -> Result<CreateTokenResponse, SpeechError> {
    use std::io::Write;

    let mut child = std::process::Command::new("curl")
        .args(["-K", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| SpeechError::Unreachable)?;
    let config = format!("url = \"{TOKEN_HOST}\"\ndata = \"{body}\"\nsilent\nmax-time = 20\n");
    child
        .stdin
        .take()
        .ok_or(SpeechError::Unreachable)?
        .write_all(config.as_bytes())
        .map_err(|_| SpeechError::Unreachable)?;
    let output = child
        .wait_with_output()
        .map_err(|_| SpeechError::Unreachable)?;
    if !output.status.success() {
        return Err(SpeechError::Unreachable);
    }
    parse_create_token(&String::from_utf8_lossy(output.stdout.as_slice()))
}

/// Read the service's reply, whichever of its two shapes it took.
pub fn parse_create_token(body: &str) -> Result<CreateTokenResponse, SpeechError> {
    let value: serde_json::Value =
        serde_json::from_str(body).map_err(|_| SpeechError::Unreachable)?;
    if let Some(token) = value.get("Token").and_then(|token| token.as_object()) {
        let id = token
            .get("Id")
            .and_then(serde_json::Value::as_str)
            .ok_or(SpeechError::Unreachable)?;
        let expires = token
            .get("ExpireTime")
            .and_then(serde_json::Value::as_i64)
            .ok_or(SpeechError::Unreachable)?;
        return Ok(CreateTokenResponse {
            id: id.to_owned(),
            expires_at: Utc
                .timestamp_opt(expires, 0)
                .single()
                .ok_or(SpeechError::Unreachable)?,
        });
    }
    Err(SpeechError::Rejected(
        value
            .get("Code")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("unknown")
            .to_owned(),
    ))
}
