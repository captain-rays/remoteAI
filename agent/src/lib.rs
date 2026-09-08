pub mod accounts;
pub mod adapters;
pub mod audit;
pub mod auth;
pub mod catalog;
pub mod config;
pub mod credentials;
pub mod crypto;
pub mod diagnostics;
pub mod discovery;
pub mod event_buffer;
pub mod files;
pub mod gateway;
pub mod health;
pub mod login;
pub mod pairing;
pub mod protocol;
pub mod provider_wiring;
pub mod speech;
pub mod store;
pub mod transfers;
pub mod tunnel;

pub const fn agent_name() -> &'static str {
    "RemoteAI Agent"
}

#[cfg(test)]
mod tests {
    #[test]
    fn agent_name_is_stable() {
        assert_eq!(super::agent_name(), "RemoteAI Agent");
    }
}
