# FerIDE beta v5.4 — Mimari

v5.4, FerIDE'nin Flutter + Python + Dart sürümünden (v5.3.8) **Rust çekirdeğe** geçtiği ilk sürümdür.
Amaç: her işletim sisteminde aynı davranan, kurulumu kendi yapan, çökmeye dayanıklı ve güvenli bir yerel yapay zeka IDE'si.

## Genel görünüm

```
┌──────────────────────────── feride (tek çalıştırılabilir dosya) ────────────────────────────┐
│                                                                                              │
│  Masaüstü kabuğu (tao + wry)          Yerel sunucu (axum, 127.0.0.1, rastgele port + jeton)  │
│  WebView2 / WKWebView / WebKitGTK ───►  /            arayüz dosyaları (gömülü)               │
│                                        /ws           JSON-RPC + olay akışı (WebSocket)       │
│                                              │                                               │
│                                              ▼                                               │
│                                     feride-core (kütüphane)                                  │
│   ┌──────────┬──────────┬───────────┬──────────┬──────────┬──────────┬──────────┬─────────┐  │
│   │ llama    │ hub      │ agent     │ mcp      │ skills   │ memory   │ terminal │ deps    │  │
│   │ sunucu   │ HF arama │ döngü,    │ stdio    │ SKILL.md │ SQLite + │ PTY      │ kurulum │  │
│   │ yönetimi │ indirme  │ araçlar,  │ istemci  │ dizini   │ FTS5     │ (ConPTY) │ ve tanı │  │
│   │ planlayıcı│ (devam) │ izinler   │          │          │          │          │         │  │
│   └────┬─────┴──────────┴───────────┴────┬─────┴──────────┴──────────┴──────────┴─────────┘  │
│        │  İş Nesnesi (Windows) / süreç grubu (Unix): FerIDE kapanınca hepsi kapanır          │
└────────┼────────────────────────────────────┼────────────────────────────────────────────────┘
         ▼                                    ▼
   llama-server (llama.cpp)          MCP sunucuları, ajan komutları, isteğe bağlı Python
                                     (belge stüdyosu, ses) — hepsi kullanıcı klasöründe
```

## Neden bu tasarım?

| Sorun (v5.3.8) | v5.4'teki çözüm |
|---|---|
| Ajan, model ve arayüz tek Flutter sürecindeydi; GPU belleği bitince arayüzle birlikte ajan da çöküyordu. | Arayüz WebView'in ayrı sürecinde çizilir. Çekirdek Rust sürecinde kalır. Arayüz çökse de ajan ve model sürer. |
| Windows'ta ajan komutları PowerShell'de çalışıyordu; modellerin yazdığı bash komutları hata veriyordu. | Windows'ta **Git Bash** (yoksa kurulumda taşınabilir Git indirilir), yoksa PowerShell. Ajan hangi kabukta olduğunu sistem talimatından bilir. |
| FerIDE kapanınca/çökünce llama-server ve Python sunucuları açık kalıyordu (GPU belleği ve port dolu). | Her alt süreç bir **İş Nesnesi**'ne (Job Object, "kapanınca öldür") bağlanır. Unix'te süreç grubu + `PDEATHSIG`. |
| Windows'ta süreç denetimi körtü (`_pidAlive` her zaman `true`). | Süreçler çekirdekte tutuluyor; PID tahmini yok. |
| Her TTS cümlesi ve RAM ölçümü için yeni bir PowerShell açılıyordu (yüzlerce ms). | Ses arayüzde (WebView) çalınıyor; ölçümler `sysinfo` ile süreç içinde. |
| `npx` gibi `.cmd` komutları Windows'ta doğrudan başlatılamıyordu (MCP sunucuları açılmıyordu). | Komut çözümleyici `.exe/.cmd/.bat` uzantılarını PATH'te arar, `.cmd`'yi `cmd /C` ile çalıştırır. |
| Kurulum Flutter + Visual Studio + Python derlemesi istiyordu (20-40 dk). | Tek dosya. İlk açılışta kurulum sihirbazı eksikleri tespit edip kullanıcı klasörüne kurar. |
| Sohbetler her token'da bütün JSON yeniden yazılarak saklanıyordu. | Oturum başına salt-ekleme **JSONL** günlüğü (çökmede kayıp yok). |
| Ajan kendi izin ayarlarını değiştirebilirdi. | FerIDE yapılandırması, sırlar ve `.ssh` gibi hassas yollar korumalı. |

## Modüller (`crates/feride-core/src`)

| Modül | Görev |
|---|---|
| `paths` | Veri dizini: `~/.feride` (v5.3.8 ile aynı; modeller, skill'ler, MCP ayarı yerinde kalır). |
| `config` | `config.toml` ayarları; atomik kayıt. |
| `secrets` | API anahtarları: Windows'ta DPAPI ile şifreli, Unix'te 0600 izinli dosya. |
| `proc` | Alt süreç başlatma: gizli pencere, İş Nesnesi/süreç grubu, ağaç halinde sonlandırma, `.cmd` çözümleme, araç PATH'i. |
| `shell` | Kabuk tespiti (Git Bash / PowerShell / bash / zsh). |
| `hardware` | RAM, çekirdek, GPU belleği (`llama-server --list-devices`), paylaşımlı bellek tespiti. |
| `gguf` | GGUF başlık okuyucu: mimari, katman, KV ihtiyacı, MoE uzman boyutu. |
| `planner` | Bellek-farkında başlatma planı (v5.3.8'den birebir taşındı, testleriyle). |
| `llama` | llama-server yaşam döngüsü: tek model, sağlık denetimi, günlük, çökme nedeni. |
| `hub` | Hugging Face arama, devam ettirilebilir indirme, SHA-256 doğrulama. |
| `deps` | Bağımlılık tespiti ve kurulumu; yönetici isteyen işler **tek seferde** toplanır. |
| `llm` | OpenAI uyumlu akışlı istemci; yerel araç çağrısı ayrıştırma (`<tool_call>`). |
| `agent` | Ajan döngüsü, araçlar, izin katmanı, bağlam sıkıştırma, alt ajan, kontrol noktaları. |
| `sessions` | JSONL oturum günlüğü, başlık, yapılacaklar, geri alma noktaları. |
| `skills` | `SKILL.md` dosyaları tek doğru kaynak; veritabanı kopyası yok. |
| `memory` | Aegis hafıza: SQLite + FTS5 (v5.3.8 deneyimleri taşınır). |
| `mcp` | MCP stdio istemcisi: başlatma, araç listesi, çağrı, `roots`, `ping`. |
| `voice` | İsteğe bağlı Python STT/TTS sunucularının denetimi; ses arayüzde çalınır. |
| `terminal` | Gerçek terminal (ConPTY / PTY) + xterm.js. |
| `fsops` | Gezgin, düzenleyici, arama ve git durumu için dosya işlemleri. |

## Güvenlik katmanları

1. **Yerel sunucu:** yalnızca `127.0.0.1`, her açılışta yeni rastgele jeton, `Origin` denetimi, sıkı CSP. Jeton URL'nin `#` kısmında taşınır (sunucu günlüklerine düşmez).
2. **İzin modları:** Plan (salt okunur) · Sor · Düzenlemelere izin ver (varsayılan) · Tam otonom.
3. **Hiçbir modda çalışmayan komutlar:** disk biçimlendirme, `rm -rf /`, `format C:`, `diskpart`, gölge kopya silme, `bcdedit`, fork bomb vb.
4. **Korumalı yollar:** `~/.ssh`, `~/.aws`, `~/.gnupg`, başlangıç klasörleri, FerIDE'nin kendi ayarları ve sırları.
5. **Güvenilmeyen içerik:** web sayfası, belge ve MCP çıktıları modele `<untrusted_content>` içinde verilir; sistem talimatı bunların komut olmadığını belirtir.
6. **Ağ:** ajanın yerel ağ/loopback adreslerine erişimi her zaman onaya tabi (SSRF koruması).
7. **Kontrol noktaları:** ajanın değiştirdiği her dosyanın önceki hali saklanır; tek tıkla geri alınır.
8. **Markdown:** DOMPurify ile temizlenir; harici bağlantılar sistem tarayıcısında açılır.

## Kurulum akışı (ilk açılış)

1. `deps` modülü eksikleri listeler: llama.cpp (gerekli), Git/bash, uv + Python ortamı (belge/ses), Node.js (MCP), WebView2, VC++ çalışma zamanı.
2. Yönetici gerektirmeyenler doğrudan `~/.feride/tools` ve `~/.feride/bin` altına kurulur.
3. Yönetici gerektirenler (VC++ çalışma zamanı, uzun dosya yolları; Linux'ta sistem paketleri) **tek bir betikte** toplanır ve tek UAC/pkexec onayıyla çalıştırılır. Sonuç `state.json`'a yazılır; bir daha sorulmaz.

## Yol haritası

| Sürüm | İçerik |
|---|---|
| **5.4** | Rust çekirdek, yeni arayüz, kurulum sihirbazı, ajan + MCP + skill + hafıza, model merkezi, terminal, ses (Python denetimli). |
| 5.5 | Ses: sherpa-onnx ile süreç içinde STT/TTS/VAD, yankı engelleme, sesle söz kesme. |
| 5.6 | İşletim sistemi düzeyinde korumalı alan (AppContainer / bubblewrap / sandbox-exec), imzalı paketler, otomatik güncelleme. |
