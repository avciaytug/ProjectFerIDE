# FerIDE beta v5.4

**FerIDE**, kendi bilgisayarınızda çalışan, Türkçe konuşan, ajan tabanlı bir yapay zeka geliştirme ortamıdır.
Yerel GGUF modellerini `llama.cpp` ile çalıştırır; kod yazar, dosya düzenler, komut çalıştırır, araştırma yapar,
belgelerle çalışır. Verileriniz bilgisayarınızdan çıkmaz.

v5.4, FerIDE'nin **Rust**'a geçtiği sürümdür: tek bir çalıştırılabilir dosya, kendi kendini kuran bağımlılıklar,
Windows, Linux ve macOS'ta aynı davranış.

## Özellikler

- **Ajan:** dosya okuma/yazma/düzenleme, arama, kabuk komutları (Windows'ta Git Bash), web araması, belge ve CAD
  stüdyosu, alt ajanlar, yapılacaklar listesi, kalıcı hafıza, skill'ler, MCP araçları.
- **Güvenlik:** dört izin modu (Plan · Sor · Düzenlemelere izin ver · Tam otonom), yıkıcı komut engeli,
  korumalı yollar, istem enjeksiyonuna karşı güvenilmeyen içerik ayrımı, her değişiklik için geri alma noktası.
- **Model Merkezi:** bellek-farkında başlatma planı (GPU / GPU+RAM / MoE uzmanları RAM'de / CPU), Hugging Face'ten
  devam ettirilebilir ve doğrulanmış indirme, görsel adaptörü (mmproj) eşleştirme.
- **IDE:** gezgin, git durumu, CodeMirror düzenleyici, gerçek terminal, model günlüğü.
- **Sohbet:** mesaj kutusunun altında düşünme aç/kapat ve model seçici; her yanıtta girdi/çıktı tokenları ve token/sn.
- **Canlı sesli sohbet (isteğe bağlı):** Gemini Live benzeri, araya girilebilen, tamamen yerel sesli konuşma
  (`Ctrl+Shift+V`). Whisper ile sesle yazma, Türkçe sesli yanıt (Feride — Ahenk Cep, Fahrettin — Piper).

## Kurulum

### Hazır sürüm

[Sürümler](../../releases) sayfasından işletim sisteminize uygun dosyayı indirin ve çalıştırın.
İlk açılışta kurulum sihirbazı eksikleri tespit edip kullanıcı klasörünüze kurar
(yönetici izni yalnızca gerekirse ve bir kez istenir).

Ya da tek satırla kurun (en son sürümü indirip kullanıcı klasörünüze kurar):

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.ps1 | iex
```

Linux / macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.sh | bash
```

### Kaynaktan derleme

Gereksinimler: Rust 1.89+ (`rustup`), Windows'ta Visual Studio Build Tools (C++), Linux'ta
`libwebkit2gtk-4.1-dev libgtk-3-dev libxdo-dev`.

```bash
cargo build --release
./target/release/feride            # masaüstü
./target/release/feride doctor     # tanı
./target/release/feride serve --open   # başsız: tarayıcıdan
```

## Komut satırı

| Komut | Görev |
|---|---|
| `feride` | Masaüstü uygulaması |
| `feride serve [--port N] [--open]` | Başsız sunucu; arayüze tarayıcıdan bağlanılır |
| `feride doctor` | Bağımlılık, donanım, model, MCP ve skill durumu |
| `feride setup [llama git uv node pydocs voice]` | Eksikleri kurar |

## Veri klasörü

`~/.feride` (Windows: `%USERPROFILE%\.feride`) — v5.3.8 ile aynı.

| Yol | İçerik |
|---|---|
| `config.toml` | Ayarlar |
| `models/` | GGUF modeller (`models/mmproj/` görsel adaptörleri) |
| `skills/` | Skill'ler (`SKILL.md`) |
| `sessions/` | Sohbetler (JSONL) ve geri alma noktaları |
| `memory.db` | Kalıcı hafıza |
| `mcp_config.json` | MCP sunucuları |
| `bin/llama-cpp/`, `tools/` | llama.cpp, Git, Node.js, uv |
| `logs/` | Günlükler |

## Proje yapısı

```
crates/feride-core   Rust çekirdek (model, ajan, araçlar, güvenlik, MCP, kurulum)
crates/feride-app    Masaüstü penceresi, yerel sunucu, komut satırı
ui/                  Arayüz (HTML/CSS/JS, derleme adımı yok; ikiliye gömülür)
resources/           Gömülü kaynaklar: Python belge/ses betikleri, varsayılan skill'ler
docs/                Mimari ve güvenlik belgeleri
scripts/             Kurulum betikleri
```

Ayrıntılar: [docs/MIMARI.md](docs/MIMARI.md) · Değişiklikler: [CHANGELOG.md](CHANGELOG.md)
