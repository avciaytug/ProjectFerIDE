//! Tarayıcıda ajanın hiçbir modda yapamayacağı ve yalnızca kullanıcının o an vereceği onayla yapabileceği işlemler.
//!
//! - Şifre, kart, CVV, IBAN ve tek kullanımlık kod alanlarına ajan yazamaz (kullanıcı kendisi girer).
//! - Ödeme, satın alma, rezervasyon, gönderme, başvuru, silme gibi geri dönüşü olmayabilecek düğmeler, kimlik/pasaport
//!   numarası girişi ve mesaj gönderebilecek tuşlar "Tam otonom" modunda bile her seferinde onaya gelir.

use regex::Regex;
use serde::Deserialize;
use std::sync::LazyLock;

/// Sayfadaki bir öğenin güvenlik denetimi için gereken özellikleri (page.js `info` çıktısı).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct ElementInfo {
    pub tag: String,
    pub role: String,
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub autocomplete: String,
    /// id, name, placeholder, aria-label, etiket metni… (küçük harf, boşlukla ayrılmış)
    pub attrs: String,
    pub href: String,
    pub editable: bool,
    /// Çok satırlı düzenleyici (textarea / contenteditable): Enter burada mesaj gönderebilir.
    pub multiline: bool,
    pub host: String,
    pub path: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    Ok,
    /// Kullanıcı o an onaylamalı (gerekçe).
    Confirm(String),
    /// Hiçbir modda yapılmaz (gerekçe; modele söylenir).
    Block(String),
}

/// Türkçe harfleri ve büyük/küçük farkını yok sayan karşılaştırma için sadeleştirme: "ÖDEMEYİ TAMAMLA" → "odemeyi tamamla".
pub fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            'ç' | 'Ç' => out.push('c'),
            'ğ' | 'Ğ' => out.push('g'),
            'ı' | 'I' | 'İ' | 'î' | 'Î' => out.push('i'),
            'ö' | 'Ö' => out.push('o'),
            'ş' | 'Ş' => out.push('s'),
            'ü' | 'Ü' | 'û' | 'Û' => out.push('u'),
            'â' | 'Â' => out.push('a'),
            '\u{307}' => {} // i̇ (birleşik nokta)
            c => out.extend(c.to_lowercase()),
        }
    }
    out
}

fn re(s: &str) -> Regex {
    Regex::new(s).unwrap()
}

static PASSWORD: LazyLock<Regex> = LazyLock::new(|| re(r"\b(password|passwd|passcode|sifre|parola)\b|\bpin\b"));
static CARD: LazyLock<Regex> = LazyLock::new(|| {
    re(r"card.?num|cardnumber|cc.?(num|no)\b|ccnum|credit.?card|kredi.?kart|banka.?kart|kart.?(no|num)|\bcvv|\bcvc|\bcsc\b|security.?code|guvenlik.?kodu|expir|son.?kullanma|exp.?(date|month|year)|card.?holder|kart.?sahibi|\biban\b|account.?number|hesap.?(no|numara)|routing")
});
static OTP: LazyLock<Regex> = LazyLock::new(|| {
    re(r"\botp\b|one.?time|verification.?code|dogrulama.?kod|onay.?kod|sms.?kod|\b2fa\b|totp|tek.?kullanimlik|auth.?code|security.?pin")
});
static IDENT: LazyLock<Regex> = LazyLock::new(|| {
    re(r"tc.?kimlik|\btckn\b|\btc.?no\b|kimlik.?(no|numara)|national.?id|identity.?(no|number)|passport|pasaport|\bssn\b|social.?security|vergi.?(no|numara)|tax.?id")
});
static IBAN_TEXT: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)^\s*[a-z]{2}\d{2}(\s?[a-z0-9]{4}){3,8}\s?[a-z0-9]{0,3}\s*$"));

/// Geri dönüşü olmayabilecek işlemlerin düğme adları (sadeleştirilmiş, bkz. `fold`).
static DANGER: LazyLock<Regex> = LazyLock::new(|| {
    re(concat!(
        r"\b(ode|odeme yap|odemeyi (tamamla|onayla|yap)|odemeye gec|simdi ode|guvenli ode|satin al|hemen al|siparisi? (tamamla|onayla|ver)|",
        r"rezervasyon(u)? (yap|tamamla|onayla)|rezerve et|bileti? al|kirala|gonder|basvur|basvuruyu (gonder|tamamla)|",
        r"sil|kalici olarak sil|hesabi (kapat|sil)|abone ol|aboneligi (baslat|iptal et)|uye ol|kaydol|hesap olustur|",
        r"bagis yap|para gonder|transfer et|onayla|kabul ediyorum|sozlesmeyi kabul|yayinla|paylas|indir|",
        r"pay|pay now|buy|buy now|purchase|place (your )?order|complete (order|purchase|booking|payment|reservation)|",
        r"confirm( and pay| order| booking| purchase| payment| reservation)?|book|book now|reserve|reserve now|",
        r"submit|submit application|send|send now|delete|delete account|close account|unsubscribe|subscribe|sign up|",
        r"create account|register|donate|transfer|publish|post|tweet|share|apply now|apply for|i agree|agree and continue|",
        r"accept (terms|and continue)|download)\b"
    ))
});
static CHECKOUT_PAGE: LazyLock<Regex> = LazyLock::new(|| re(r"checkout|payment|/pay\b|odeme|sepet|/cart|basket|billing|purchase"));

/// Kart numarası mı? (13-19 hane, Luhn denetimi geçer)
pub fn looks_like_card(text: &str) -> bool {
    let digits: Vec<u32> = text.chars().filter(|c| !c.is_whitespace() && *c != '-').map(|c| c.to_digit(10)).collect::<Option<_>>().unwrap_or_default();
    if !(13..=19).contains(&digits.len()) {
        return false;
    }
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(i, &d)| if i % 2 == 1 { if d * 2 > 9 { d * 2 - 9 } else { d * 2 } } else { d })
        .sum();
    sum % 10 == 0
}

/// T.C. kimlik numarası mı? (11 hane, resmi denetim haneleri)
pub fn looks_like_tckn(text: &str) -> bool {
    let t = text.trim();
    if t.len() != 11 || !t.bytes().all(|b| b.is_ascii_digit()) || t.starts_with('0') {
        return false;
    }
    let d: Vec<i32> = t.bytes().map(|b| (b - b'0') as i32).collect();
    let odd = d[0] + d[2] + d[4] + d[6] + d[8];
    let even = d[1] + d[3] + d[5] + d[7];
    let d10 = ((odd * 7 - even) % 10 + 10) % 10;
    let d11 = (d[..10].iter().sum::<i32>()) % 10;
    d[9] == d10 && d[10] == d11
}

/// Ajanın bu alana bu metni yazmasına izin var mı?
pub fn typing(f: &ElementInfo, text: &str) -> Verdict {
    let attrs = fold(&format!("{} {} {}", f.attrs, f.name, f.autocomplete));
    let ac = f.autocomplete.to_lowercase();
    if f.kind == "password" || ac.contains("password") || PASSWORD.is_match(&attrs) {
        return Verdict::Block(
            "Bu bir şifre alanı. Şifreleri ajan yazamaz: wait_for_user ile kullanıcıdan şifresini kendisinin girmesini iste.".into(),
        );
    }
    if ac.starts_with("cc-") || ac.contains(" cc-") || CARD.is_match(&attrs) {
        return Verdict::Block(
            "Bu bir kart/ödeme ya da banka hesabı alanı. Bu bilgileri ajan yazamaz: ödemeyi kullanıcıya bırak (wait_for_user).".into(),
        );
    }
    if ac.contains("one-time-code") || OTP.is_match(&attrs) {
        return Verdict::Block("Bu bir doğrulama kodu alanı. Kodu kullanıcı girmeli: wait_for_user ile iste.".into());
    }
    if looks_like_card(text) || IBAN_TEXT.is_match(text) {
        return Verdict::Block("Yazılmak istenen metin bir kart numarasına ya da IBAN'a benziyor; ajan bunu yazamaz.".into());
    }
    if IDENT.is_match(&attrs) || looks_like_tckn(text) {
        return Verdict::Confirm(format!("Kimlik/pasaport bilgisi giriliyor ({})", f.host));
    }
    Verdict::Ok
}

/// Bu öğeye tıklamak kullanıcının o anki onayını gerektiriyor mu?
pub fn click(f: &ElementInfo) -> Verdict {
    // Dosya seçme alanı işletim sisteminin dosya penceresini açar; hangi dosyanın yükleneceğine kullanıcı karar verir.
    if f.role == "file" || f.kind == "file" {
        return Verdict::Block(
            "Bu bir dosya yükleme alanı. Yüklenecek dosyayı kullanıcı seçer: wait_for_user ile hangi dosyayı yüklemesi gerektiğini söyle.".into(),
        );
    }
    let name = fold(f.name.trim());
    // Uzun metinler (makale başlığı, sonuç kartı) bir eylem düğmesi değildir.
    let short = !name.is_empty() && name.split_whitespace().count() <= 6;
    if short && DANGER.is_match(&name) {
        return Verdict::Confirm(format!("Geri dönüşü olmayabilecek işlem: \"{}\" ({})", crate::util::truncate_end(f.name.trim(), 80), f.host));
    }
    let is_button = f.role == "button" || f.kind == "submit";
    if is_button && CHECKOUT_PAGE.is_match(&fold(&f.path)) {
        return Verdict::Confirm(format!("Ödeme sayfasında bir düğme: \"{}\" ({})", crate::util::truncate_end(f.name.trim(), 80), f.host));
    }
    Verdict::Ok
}

/// Tuşa basmak (ör. Enter) bir mesaj gönderebilir mi? `focused`: o an odaktaki öğe.
pub fn keypress(key: &str, focused: Option<&ElementInfo>) -> Verdict {
    let k = key.to_lowercase();
    let enter = k.ends_with("enter") || k.ends_with("return");
    if !enter {
        return Verdict::Ok;
    }
    let host = focused.map(|f| f.host.as_str()).unwrap_or("");
    if k.contains("control") || k.contains("ctrl") || k.contains("meta") || k.contains("cmd") {
        return Verdict::Confirm(format!("Ctrl/Cmd+Enter genellikle e-postayı ya da mesajı gönderir ({host})"));
    }
    if focused.is_some_and(|f| f.multiline) {
        return Verdict::Confirm(format!("Çok satırlı bir yazı alanında Enter: sohbet ve e-posta sitelerinde mesajı gönderebilir ({host})"));
    }
    Verdict::Ok
}

/// Ajanın açamayacağı adresler (tarayıcı ayarları, betik adresleri).
pub fn url_block(url: &str) -> Option<String> {
    let l = url.trim().to_lowercase();
    for p in ["chrome://", "edge://", "brave://", "opera://", "vivaldi://", "devtools://", "chrome-extension://", "about:config"] {
        if l.starts_with(p) {
            return Some("Tarayıcının ayar ve iç sayfalarını ajan açamaz.".into());
        }
    }
    if l.starts_with("javascript:") || l.starts_with("data:") || l.starts_with("blob:") || l.starts_with("view-source:") {
        return Some("Bu tür adresleri (javascript:, data:, blob:) ajan açamaz.".into());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field(kind: &str, attrs: &str) -> ElementInfo {
        ElementInfo { tag: "input".into(), role: "textbox".into(), kind: kind.into(), attrs: attrs.into(), host: "ornek.com".into(), ..Default::default() }
    }

    #[test]
    fn secrets_are_never_typed() {
        assert!(matches!(typing(&field("password", ""), "x"), Verdict::Block(_)));
        assert!(matches!(typing(&field("text", "Şifre"), "x"), Verdict::Block(_)));
        assert!(matches!(typing(&field("text", "Kart Numarası"), "1234"), Verdict::Block(_)));
        assert!(matches!(typing(&ElementInfo { autocomplete: "cc-number".into(), ..field("tel", "") }, "1"), Verdict::Block(_)));
        assert!(matches!(typing(&field("text", "CVV"), "123"), Verdict::Block(_)));
        assert!(matches!(typing(&field("text", "Doğrulama kodu"), "123456"), Verdict::Block(_)));
        assert!(matches!(typing(&ElementInfo { autocomplete: "one-time-code".into(), ..field("text", "") }, "1"), Verdict::Block(_)));
        assert!(matches!(typing(&field("text", "IBAN"), "TR"), Verdict::Block(_)));
        // Sıradan alana yazılan kart numarası / IBAN da yazılmaz.
        assert!(matches!(typing(&field("text", "not"), "4111 1111 1111 1111"), Verdict::Block(_)));
        assert!(matches!(typing(&field("text", "not"), "TR33 0006 1005 1978 6457 8413 26"), Verdict::Block(_)));
    }

    #[test]
    fn identity_numbers_need_confirmation() {
        assert!(matches!(typing(&field("text", "Pasaport numarası"), "U12345678"), Verdict::Confirm(_)));
        assert!(matches!(typing(&field("text", "TC Kimlik No"), "1"), Verdict::Confirm(_)));
        assert!(matches!(typing(&field("text", "not"), "10000000146"), Verdict::Confirm(_)));
    }

    #[test]
    fn ordinary_typing_is_allowed() {
        assert_eq!(typing(&field("search", "Nereden?"), "İstanbul"), Verdict::Ok);
        assert_eq!(typing(&field("email", "E-posta"), "ali@example.com"), Verdict::Ok);
        assert_eq!(typing(&field("text", "Yolcu sayısı"), "2"), Verdict::Ok);
        assert_eq!(typing(&field("text", "Uçuş no"), "TK1234"), Verdict::Ok);
        // "kimlik" kelimesi geçmeyen 11 haneli sayı (ör. telefon) onaya gitmez; denetim hanesi tutmaz.
        assert_eq!(typing(&field("tel", "Telefon"), "05321234567"), Verdict::Ok);
    }

    #[test]
    fn irreversible_buttons_need_confirmation() {
        let b = |name: &str| ElementInfo { role: "button".into(), name: name.into(), host: "ornek.com".into(), path: "/".into(), ..Default::default() };
        for n in ["Öde", "ÖDEMEYİ TAMAMLA", "Satın al", "Siparişi onayla", "Rezervasyonu tamamla", "Gönder", "Sil", "Pay now", "Book", "Place order", "Submit application", "Send", "İndir", "Kalıcı olarak sil"] {
            assert!(matches!(click(&b(n)), Verdict::Confirm(_)), "{n}");
        }
        for n in ["Ara", "Uçuşları göster", "İleri", "Filtrele", "Reddet", "Tümünü reddet", "Aktarmasız", "Facebook", "Booking.com", "İndirimli fiyatlar", "Gönderiler", "Apply filters", "Uygula", "Ödeme yöntemleri"] {
            assert_eq!(click(&b(n)), Verdict::Ok, "{n}");
        }
        // Uzun bağlantı metinleri (makale başlıkları) eylem sayılmaz.
        assert_eq!(click(&b("How to send money abroad cheaply in 2026 guide")), Verdict::Ok);
        // Ödeme sayfasında herhangi bir düğme onaya gider.
        let mut c = b("Devam");
        c.path = "/checkout/step-2".into();
        assert!(matches!(click(&c), Verdict::Confirm(_)));
        // Dosya seçme alanına ajan tıklamaz (işletim sisteminin penceresi açılır; dosyayı kullanıcı seçer).
        let f = ElementInfo { role: "file".into(), kind: "file".into(), name: "Pasaport fotokopisi".into(), ..Default::default() };
        assert!(matches!(click(&f), Verdict::Block(_)));
    }

    #[test]
    fn enter_in_message_boxes_needs_confirmation() {
        let multi = ElementInfo { multiline: true, host: "web.whatsapp.com".into(), ..Default::default() };
        let single = ElementInfo { multiline: false, host: "google.com".into(), ..Default::default() };
        assert!(matches!(keypress("Enter", Some(&multi)), Verdict::Confirm(_)));
        assert_eq!(keypress("Enter", Some(&single)), Verdict::Ok);
        assert!(matches!(keypress("Control+Enter", Some(&single)), Verdict::Confirm(_)));
        assert_eq!(keypress("Tab", Some(&multi)), Verdict::Ok);
    }

    #[test]
    fn helpers() {
        assert!(looks_like_card("4111-1111-1111-1111"));
        assert!(!looks_like_card("4111 1111 1111 1112"));
        assert!(!looks_like_card("12345"));
        assert!(looks_like_tckn("10000000146"));
        assert!(!looks_like_tckn("12345678901"));
        assert_eq!(fold("ÖDEMEYİ TAMAMLA"), "odemeyi tamamla");
        assert_eq!(fold("Satın Al"), "satin al");
        assert!(url_block("chrome://settings").is_some());
        assert!(url_block("javascript:alert(1)").is_some());
        assert!(url_block("https://www.google.com/travel/flights").is_none());
    }
}
