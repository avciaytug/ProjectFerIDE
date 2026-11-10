//! Çekirdekten arayüze olay akışı.

use serde::Serialize;
use serde_json::Value;
use tokio::sync::broadcast;

#[derive(Clone, Debug, Serialize)]
pub struct Event {
    pub topic: String,
    pub data: Value,
}

#[derive(Clone)]
pub struct EventBus {
    tx: broadcast::Sender<Event>,
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}

impl EventBus {
    pub fn new() -> Self {
        let (tx, _) = broadcast::channel(4096);
        Self { tx }
    }

    pub fn emit(&self, topic: &str, data: Value) {
        let _ = self.tx.send(Event { topic: topic.to_string(), data });
    }

    pub fn emit_ser<T: Serialize>(&self, topic: &str, data: &T) {
        if let Ok(v) = serde_json::to_value(data) {
            self.emit(topic, v);
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.tx.subscribe()
    }
}
