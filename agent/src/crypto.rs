use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use hkdf::Hkdf;
use p256::ecdh::diffie_hellman;
use p256::{PublicKey, SecretKey};
use sha2::Sha256;
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
    #[error("counter {received} was already accepted; last counter is {last}")]
    Replay { received: u64, last: u64 },
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
