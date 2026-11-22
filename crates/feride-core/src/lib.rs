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
pub mod install;
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
pub mod update;
pub mod util;
pub mod voice;
#[cfg(windows)]
pub mod winint;
pub mod winsec;

pub use crate::core::Core;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// Arayüzde gösterilen sürüm: `5.4.25-beta` → `v5.4.25 beta`.
pub const DISPLAY_VERSION: &str = concat!(
    "v",
    env!("CARGO_PKG_VERSION_MAJOR"),
    ".",
    env!("CARGO_PKG_VERSION_MINOR"),
    ".",
    env!("CARGO_PKG_VERSION_PATCH"),
    " ",
    env!("CARGO_PKG_VERSION_PRE")
);

/// Herhangi bir sürüm metnini gösterim biçimine çevirir: `5.4.26-beta` → `v5.4.26 beta`,
/// eski biçim `5.4.0-beta.24` → `v5.4.0 beta.24`.
pub fn display_version(v: &str) -> String {
    let v = v.trim().trim_start_matches(['v', 'V']);
    match v.split_once('-') {
        Some((core, pre)) => format!("v{core} {pre}"),
        None => format!("v{v}"),
    }
}

#[cfg(test)]
mod version_tests {
    #[test]
    fn display_version_format() {
        // Sürümde ön ek (beta) yoksa DISPLAY_VERSION sonda boşluk bırakır; bu eşitlik onu yakalar.
        assert_eq!(super::DISPLAY_VERSION, super::display_version(super::VERSION));
        assert_eq!(super::display_version("5.4.26-beta"), "v5.4.26 beta");
        assert_eq!(super::display_version("v5.4.0-beta.24"), "v5.4.0 beta.24");
        assert_eq!(super::display_version("5.5.0"), "v5.5.0");
    }
}
