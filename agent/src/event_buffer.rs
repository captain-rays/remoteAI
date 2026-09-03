use std::collections::{HashMap, VecDeque};

use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub struct BufferedEvent {
    pub conversation_id: String,
    pub sequence: u64,
    pub payload: Value,
}

#[derive(Debug)]
pub struct EventBuffer {
    capacity: usize,
    events: HashMap<String, VecDeque<BufferedEvent>>,
    next_sequence: HashMap<String, u64>,
}

impl EventBuffer {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "event buffer capacity must be positive");
        Self {
            capacity,
            events: HashMap::new(),
            next_sequence: HashMap::new(),
        }
    }

    pub fn push(&mut self, conversation_id: &str, payload: Value) -> BufferedEvent {
        let sequence = self
            .next_sequence
            .entry(conversation_id.to_owned())
            .and_modify(|value| *value += 1)
            .or_insert(1)
            .to_owned();
        let event = BufferedEvent {
            conversation_id: conversation_id.to_owned(),
            sequence,
            payload,
        };
        let queue = self.events.entry(conversation_id.to_owned()).or_default();
        queue.push_back(event.clone());
        while queue.len() > self.capacity {
            queue.pop_front();
        }
        event
    }

    pub fn after(&self, conversation_id: &str, last_sequence: u64) -> Vec<BufferedEvent> {
        self.events
            .get(conversation_id)
            .into_iter()
            .flatten()
            .filter(|event| event.sequence > last_sequence)
            .cloned()
            .collect()
    }
}
