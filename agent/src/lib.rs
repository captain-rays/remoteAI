pub mod adapters;
pub mod audit;
pub mod catalog;
pub mod config;
pub mod crypto;
pub mod diagnostics;
pub mod discovery;
pub mod event_buffer;
pub mod files;
pub mod gateway;
pub mod pairing;
pub mod protocol;
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
