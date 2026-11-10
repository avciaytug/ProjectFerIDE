//! Uygulamaya gömülü kaynaklar (Python betikleri, varsayılan skill'ler).
//!
//! Tek çalıştırılabilir dosya dağıtımı için kaynaklar ikiliye gömülür ve ilk açılışta
//! (ya da sürüm değişince) `~/.feride/resources` altına açılır. Kullanıcının
//! düzenlediği skill'lerin üzerine yazılmaz.

use rust_embed::RustEmbed;
use std::path::Path;

use crate::paths::Paths;

#[derive(RustEmbed)]
#[folder = "../../resources/"]
struct Embedded;

pub fn install(paths: &Paths, deps: &crate::deps::Deps) {
    let version = crate::VERSION.to_string();
    let fresh = deps.state().resources_version.as_deref() != Some(version.as_str());
    let res_root = paths.resources();
    for file in Embedded::iter() {
        let file = file.as_ref();
        let Some(data) = Embedded::get(file) else { continue };
        if let Some(rest) = file.strip_prefix("skills/") {
            // Skill'ler: yalnızca eksikse kopyala (kullanıcı düzenlemeleri korunur).
            let dest = paths.skills().join(rest);
            if !dest.exists() {
                write(&dest, &data.data);
            }
        } else {
            let dest = res_root.join(file);
            if fresh || !dest.exists() {
                write(&dest, &data.data);
            }
        }
    }
    if fresh {
        deps.update_state(|s| s.resources_version = Some(version));
    }
}

fn write(dest: &Path, data: &[u8]) {
    if let Some(p) = dest.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    if let Err(e) = std::fs::write(dest, data) {
        tracing::warn!("kaynak yazılamadı {}: {e}", dest.display());
    }
}
