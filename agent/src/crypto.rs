use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use hkdf::Hkdf;
use p256::ecdh::diffie_hellman;
use p256::elliptic_curve::rand_core::OsRng;
use p256::{PublicKey, SecretKey};
use sha2::Sha256;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use thiserror::Error;
use zeroize::Zeroizing;

#[derive(Debug, Error)]
pub enum CryptoError {
    #[error("invalid P-256 private key")]
    InvalidPrivateKey,
    #[error("invalid P-256 public key")]
    InvalidPublicKey,
    #[error("key derivation failed")]
    KeyDerivation,
    #[error("authenticated encryption failed")]
    Encryption,
    #[error("private key storage failed: {0}")]
    Storage(String),
    #[error("counter {received} was already accepted; last counter is {last}")]
    Replay { received: u64, last: u64 },
}

pub fn load_or_create_private_key(path: &Path) -> Result<SecretKey, CryptoError> {
    if path.exists()
        && path
            .metadata()
            .map_err(|error| CryptoError::Storage(error.to_string()))?
            .len()
            > 0
    {
        let mut bytes = Vec::new();
        fs::File::open(path)
            .and_then(|mut file| file.read_to_end(&mut bytes))
            .map_err(|error| CryptoError::Storage(error.to_string()))?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| CryptoError::Storage(error.to_string()))?;
        return SecretKey::from_slice(&bytes).map_err(|_| CryptoError::InvalidPrivateKey);
    }
    let secret = SecretKey::random(&mut OsRng);
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| CryptoError::Storage(error.to_string()))?;
    file.write_all(&secret.to_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|error| CryptoError::Storage(error.to_string()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|error| CryptoError::Storage(error.to_string()))?;
    Ok(secret)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectionalKeys {
    pub mac_to_ios: Zeroizing<[u8; 32]>,
    pub ios_to_mac: Zeroizing<[u8; 32]>,
}

pub fn derive_shared_secret(
    private_key: &[u8],
    peer_public_key: &[u8],
) -> Result<Zeroizing<[u8; 32]>, CryptoError> {
    let secret = SecretKey::from_slice(private_key).map_err(|_| CryptoError::InvalidPrivateKey)?;
    let public =
        PublicKey::from_sec1_bytes(peer_public_key).map_err(|_| CryptoError::InvalidPublicKey)?;
    let shared = diffie_hellman(secret.to_nonzero_scalar(), public.as_affine());
    let mut bytes = [0; 32];
    bytes.copy_from_slice(shared.raw_secret_bytes());
    Ok(Zeroizing::new(bytes))
}

pub fn derive_directional_keys(
    shared_secret: &Zeroizing<[u8; 32]>,
    mac_id: &str,
    device_id: &str,
) -> Result<DirectionalKeys, CryptoError> {
    let hkdf = Hkdf::<Sha256>::new(Some(b"RemoteAI protocol v1"), &shared_secret[..]);
    let mut mac_to_ios = Zeroizing::new([0; 32]);
    let mut ios_to_mac = Zeroizing::new([0; 32]);
    hkdf.expand(
        format!("mac->ios|{mac_id}|{device_id}").as_bytes(),
        mac_to_ios.as_mut(),
    )
    .map_err(|_| CryptoError::KeyDerivation)?;
    hkdf.expand(
        format!("ios->mac|{mac_id}|{device_id}").as_bytes(),
        ios_to_mac.as_mut(),
    )
    .map_err(|_| CryptoError::KeyDerivation)?;
    Ok(DirectionalKeys {
        mac_to_ios,
        ios_to_mac,
    })
}

#[derive(Clone)]
pub struct CryptoBox {
    cipher: Aes256Gcm,
    nonce_prefix: [u8; 4],
}

impl CryptoBox {
    pub fn new(key: [u8; 32], nonce_prefix: [u8; 4]) -> Self {
        Self {
            cipher: Aes256Gcm::new((&key).into()),
            nonce_prefix,
        }
    }

    pub fn encrypt(
        &self,
        counter: u64,
        associated_data: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        self.cipher
            .encrypt(
                &self.nonce(counter),
                Payload {
                    msg: plaintext,
                    aad: associated_data,
                },
            )
            .map_err(|_| CryptoError::Encryption)
    }

    pub fn receiver(&self) -> CryptoReceiver {
        CryptoReceiver {
            crypto: self.clone(),
            last_counter: None,
        }
    }

    fn nonce(&self, counter: u64) -> Nonce<aes_gcm::aead::consts::U12> {
        let mut nonce = [0; 12];
        nonce[..4].copy_from_slice(&self.nonce_prefix);
        nonce[4..].copy_from_slice(&counter.to_be_bytes());
        nonce.into()
    }
}

pub struct CryptoReceiver {
    crypto: CryptoBox,
    last_counter: Option<u64>,
}

impl CryptoReceiver {
    pub fn decrypt(
        &mut self,
        counter: u64,
        associated_data: &[u8],
        ciphertext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        if let Some(last) = self.last_counter
            && counter <= last
        {
            return Err(CryptoError::Replay {
                received: counter,
                last,
            });
        }
        let plaintext = self
            .crypto
            .cipher
            .decrypt(
                &self.crypto.nonce(counter),
                Payload {
                    msg: ciphertext,
                    aad: associated_data,
                },
            )
            .map_err(|_| CryptoError::Encryption)?;
        self.last_counter = Some(counter);
        Ok(plaintext)
    }
}
