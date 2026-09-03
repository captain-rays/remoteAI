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
