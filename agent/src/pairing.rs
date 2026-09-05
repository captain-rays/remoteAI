use std::collections::HashMap;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingPayload {
    pub origin: String,
    pub mac_id: String,
    pub mac_public_key: Vec<u8>,
    pub pairing_secret: String,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct PairedDevice {
    pub id: String,
    pub label: String,
    pub public_key: Vec<u8>,
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone)]
struct PendingSecret {
    expires_at: DateTime<Utc>,
    used: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum PairingError {
    #[error("pairing secret is unknown")]
    SecretUnknown,
    #[error("pairing secret has expired")]
    SecretExpired,
    #[error("pairing secret has already been used")]
    SecretAlreadyUsed,
    #[error("device is unknown")]
    DeviceUnknown,
    #[error("device has been revoked")]
    DeviceRevoked,
}

pub struct PairingRegistry {
    mac_id: String,
    origin: String,
    mac_public_key: Vec<u8>,
    pending: HashMap<String, PendingSecret>,
    devices: HashMap<String, PairedDevice>,
}

impl PairingRegistry {
    pub fn new(mac_id: &str, origin: &str, mac_public_key: Vec<u8>) -> Self {
        Self {
            mac_id: mac_id.to_owned(),
            origin: origin.to_owned(),
            mac_public_key,
            pending: HashMap::new(),
            devices: HashMap::new(),
        }
    }

    pub fn issue(&mut self, secret: &str, now: DateTime<Utc>) -> PairingPayload {
        let expires_at = now + Duration::minutes(5);
        self.pending.insert(
            secret.to_owned(),
            PendingSecret {
                expires_at,
                used: false,
            },
        );
        PairingPayload {
            origin: self.origin.clone(),
            mac_id: self.mac_id.clone(),
            mac_public_key: self.mac_public_key.clone(),
            pairing_secret: secret.to_owned(),
            expires_at,
        }
    }

    pub fn pair(
        &mut self,
        secret: &str,
        device_id: &str,
        label: &str,
        public_key: Vec<u8>,
        now: DateTime<Utc>,
    ) -> Result<PairedDevice, PairingError> {
        let pending = self
            .pending
            .get_mut(secret)
            .ok_or(PairingError::SecretUnknown)?;
        if pending.used {
            return Err(PairingError::SecretAlreadyUsed);
        }
        if now > pending.expires_at {
            return Err(PairingError::SecretExpired);
        }
        pending.used = true;
        let device = PairedDevice {
            id: device_id.to_owned(),
            label: label.to_owned(),
            public_key,
            revoked_at: None,
        };
        self.devices.insert(device_id.to_owned(), device.clone());
        // Returned so the caller can persist it: a phone should pair once.
        Ok(device)
    }

    /// Rebuild the known devices after a restart.
    ///
    /// Pending one-time secrets are deliberately not restored — a secret that
    /// outlived the process that issued it could be replayed against the new
    /// one.
    pub fn restore(&mut self, devices: Vec<PairedDevice>) {
        for device in devices {
            self.devices.insert(device.id.clone(), device);
        }
    }

    pub fn authenticate(&self, device_id: &str) -> Result<(), PairingError> {
        let device = self
            .devices
            .get(device_id)
            .ok_or(PairingError::DeviceUnknown)?;
        if device.revoked_at.is_some() {
            Err(PairingError::DeviceRevoked)
        } else {
            Ok(())
        }
    }

    pub fn mac_id(&self) -> &str {
        &self.mac_id
    }

    pub fn mac_public_key(&self) -> Vec<u8> {
        self.mac_public_key.clone()
    }

    pub fn device_public_key(&self, device_id: &str) -> Result<Vec<u8>, PairingError> {
        self.authenticate(device_id)?;
        self.devices
            .get(device_id)
            .map(|device| device.public_key.clone())
            .ok_or(PairingError::DeviceUnknown)
    }

    pub fn revoke(&mut self, device_id: &str, now: DateTime<Utc>) -> Result<(), PairingError> {
        let device = self
            .devices
            .get_mut(device_id)
            .ok_or(PairingError::DeviceUnknown)?;
        device.revoked_at = Some(now);
        Ok(())
    }
}
