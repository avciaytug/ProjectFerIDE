//! FerIDE çekirdeği: model yönetimi, ajan, araçlar, MCP, skill, hafıza, kurulum.

pub mod agent;
pub mod config;
pub mod core;
pub mod deps;
pub mod events;
pub mod fsops;
pub mod gguf;
pub mod hardware;
pub mod hub;
pub mod llama;
pub mod llm;
pub mod mcp;
pub mod memory;
pub mod paths;
pub mod planner;
pub mod proc;
pub mod resources;
pub mod secrets;
pub mod sessions;
pub mod shell;
pub mod skills;
pub mod terminal;
pub mod util;
pub mod voice;

pub use crate::core::Core;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const DISPLAY_VERSION: &str = "beta v5.4";
