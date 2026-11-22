//! Klavye tuşlarının CDP (`Input.dispatchKeyEvent`) karşılıkları.

use serde_json::{json, Value};

/// CDP değiştirici bitleri.
pub const ALT: i64 = 1;
pub const CTRL: i64 = 2;
pub const META: i64 = 4;
pub const SHIFT: i64 = 8;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Key {
    pub key: String,
    pub code: String,
    pub vk: i64,
    pub text: Option<String>,
}

fn named(key: &str, code: &str, vk: i64, text: Option<&str>) -> Option<Key> {
    Some(Key { key: key.into(), code: code.into(), vk, text: text.map(String::from) })
}

/// Tek bir tuşun tanımı ("Enter", "ArrowDown", "a", "F5"…).
pub fn key_def(name: &str) -> Option<Key> {
    let n = name.to_lowercase();
    match n.as_str() {
        "enter" | "return" => named("Enter", "Enter", 13, Some("\r")),
        "tab" => named("Tab", "Tab", 9, None),
        "escape" | "esc" => named("Escape", "Escape", 27, None),
        "backspace" => named("Backspace", "Backspace", 8, None),
        "delete" | "del" => named("Delete", "Delete", 46, None),
        "space" | " " => named(" ", "Space", 32, Some(" ")),
        "arrowup" | "up" => named("ArrowUp", "ArrowUp", 38, None),
        "arrowdown" | "down" => named("ArrowDown", "ArrowDown", 40, None),
        "arrowleft" | "left" => named("ArrowLeft", "ArrowLeft", 37, None),
        "arrowright" | "right" => named("ArrowRight", "ArrowRight", 39, None),
        "home" => named("Home", "Home", 36, None),
        "end" => named("End", "End", 35, None),
        "pageup" => named("PageUp", "PageUp", 33, None),
        "pagedown" => named("PageDown", "PageDown", 34, None),
        "insert" => named("Insert", "Insert", 45, None),
        _ => {
            if let Some(f) = n.strip_prefix('f').and_then(|d| d.parse::<i64>().ok()).filter(|d| (1..=12).contains(d)) {
                return Some(Key { key: format!("F{f}"), code: format!("F{f}"), vk: 111 + f, text: None });
            }
            let mut it = name.chars();
            let c = it.next()?;
            if it.next().is_some() {
                return None;
            }
            if c.is_ascii_alphabetic() {
                let up = c.to_ascii_uppercase();
                return Some(Key { key: c.to_string(), code: format!("Key{up}"), vk: up as i64, text: Some(c.to_string()) });
            }
            if c.is_ascii_digit() {
                return Some(Key { key: c.to_string(), code: format!("Digit{c}"), vk: c as i64, text: Some(c.to_string()) });
            }
            Some(Key { key: c.to_string(), code: String::new(), vk: 0, text: Some(c.to_string()) })
        }
    }
}

/// "Control+Shift+Tab" gibi bir birleşimi çözer: (değiştiriciler, tuş).
pub fn parse_combo(spec: &str) -> Result<(i64, Key), String> {
    let spec = spec.trim();
    // "Control++" → son parça "+" tuşu
    let parts: Vec<&str> = if spec.ends_with("++") {
        let mut p: Vec<&str> = spec[..spec.len() - 2].split('+').collect();
        p.push("+");
        p
    } else {
        spec.split('+').collect()
    };
    let parts: Vec<&str> = parts.into_iter().map(str::trim).filter(|p| !p.is_empty()).collect();
    let Some((last, mods)) = parts.split_last() else { return Err("tuş boş".into()) };
    let mut m = 0;
    for p in mods {
        match p.to_lowercase().as_str() {
            "alt" | "option" | "altgr" => m |= ALT,
            "ctrl" | "control" => m |= CTRL,
            "meta" | "cmd" | "command" | "win" | "super" => m |= META,
            "shift" => m |= SHIFT,
            other => return Err(format!("bilinmeyen değiştirici tuş: {other}")),
        }
    }
    let mut k = key_def(last).ok_or_else(|| format!("bilinmeyen tuş: {last} (ör. Enter, Tab, Escape, ArrowDown, PageDown, a)"))?;
    if m & SHIFT != 0 && k.key.chars().count() == 1 && k.key.chars().all(|c| c.is_ascii_alphabetic()) {
        k.key = k.key.to_uppercase();
        k.text = Some(k.key.clone());
    }
    Ok((m, k))
}

/// Ctrl/Cmd ile basılan düzenleme kısayolunun tarayıcı komutu. Komut adıyla gönderilince macOS'ta da çalışır.
pub fn editing_command(mods: i64, key: &str) -> Option<&'static str> {
    if mods & (CTRL | META) == 0 {
        return None;
    }
    match key.to_lowercase().as_str() {
        "a" => Some("selectAll"),
        "c" => Some("copy"),
        "v" => Some("paste"),
        "x" => Some("cut"),
        "z" => Some(if mods & SHIFT != 0 { "redo" } else { "undo" }),
        "y" => Some("redo"),
        _ => None,
    }
}

/// Basma ve bırakma olayları.
pub fn key_events(mods: i64, k: &Key) -> (Value, Value) {
    let text = if mods & (ALT | CTRL | META) == 0 { k.text.clone() } else { None };
    let mut down = json!({
        "type": if text.is_some() { "keyDown" } else { "rawKeyDown" },
        "modifiers": mods, "key": k.key, "code": k.code,
        "windowsVirtualKeyCode": k.vk, "nativeVirtualKeyCode": k.vk,
    });
    if let Some(t) = &text {
        down["text"] = json!(t);
        down["unmodifiedText"] = json!(t);
    }
    if let Some(c) = editing_command(mods, &k.key) {
        down["commands"] = json!([c]);
    }
    let up = json!({
        "type": "keyUp", "modifiers": mods, "key": k.key, "code": k.code,
        "windowsVirtualKeyCode": k.vk, "nativeVirtualKeyCode": k.vk,
    });
    (down, up)
}

/// Platformun "tümünü seç" değiştiricisi.
pub fn select_all_modifier() -> i64 {
    if cfg!(target_os = "macos") {
        META
    } else {
        CTRL
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn combos() {
        let (m, k) = parse_combo("Enter").unwrap();
        assert_eq!((m, k.vk, k.text.as_deref()), (0, 13, Some("\r")));
        let (m, k) = parse_combo("Control+a").unwrap();
        assert_eq!((m, k.code.as_str()), (CTRL, "KeyA"));
        assert_eq!(editing_command(m, &k.key), Some("selectAll"));
        let (m, k) = parse_combo("Shift+Tab").unwrap();
        assert_eq!((m, k.key.as_str()), (SHIFT, "Tab"));
        let (_, k) = parse_combo("shift+b").unwrap();
        assert_eq!(k.text.as_deref(), Some("B"));
        let (m, k) = parse_combo("Ctrl++").unwrap();
        assert_eq!((m, k.key.as_str()), (CTRL, "+"));
        assert_eq!(parse_combo("F5").unwrap().1.vk, 116);
        assert!(parse_combo("Hyper+x").is_err());
        assert!(parse_combo("Nope").is_err());
        // Ctrl ile metin gönderilmez (yoksa harf yazılır).
        let (m, k) = parse_combo("Ctrl+c").unwrap();
        let (down, _) = key_events(m, &k);
        assert!(down.get("text").is_none());
        assert_eq!(down["commands"][0], "copy");
    }
}
