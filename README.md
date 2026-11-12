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
  (`Ctrl+Shift+V`). Whisper ile sesle yazma, Türkçe sesli yanıt (Feride — Ahenk Cep; erkek ses — Piper DFKI).

## Kurulum

**Gereksinimler:** Windows 10/11 (x64), Linux (x64, WebKitGTK 4.1) ya da Apple Silicon Mac.
En az 16 GB RAM önerilir; ekran kartı (Vulkan / Metal) isteğe bağlıdır ama modelleri ve konuşma tanımayı çok hızlandırır.
Yönetici izni gerekmez.

**Nereye kurulacağını siz seçersiniz.** Kurulum sihirbazı iki klasör sorar; ikisi de herhangi bir sürücüde
(C:, D:…) ya da disk bölümünde (`/home`, `/mnt/disk2`…) olabilir, **Değiştir…** ile seçilir ya da elle yazılır:

| Klasör | İçerik | Varsayılan |
|---|---|---|
| **Program klasörü** | `feride.exe` (~25 MB) | Windows `%LOCALAPPDATA%\Programs\FerIDE`, Linux `~/.local/share/feride`, macOS `~/Applications/FerIDE` |
| **Veri klasörü** | modeller, llama.cpp, ses paketi, sohbetler, ayarlar (onlarca GB olabilir) | `~/.feride` (Windows `%USERPROFILE%\.feride`) |

Sihirbaz seçilen sürücüdeki boş alanı gösterir; seçilen klasörde FerIDE verileri varsa (ör. başka bir diske
taşıdığınız modeller) onları tanır ve kullanmaya devam eder. Masaüstü/Başlat menüsü kısayolu ve komut satırından
`feride` olarak çalıştırma isteğe bağlıdır. Sürücü kökü, ev klasörü ve sistem klasörleri seçilemez; bunlar
seçilirse içine bir `FerIDE` klasörü açılır.

### Windows

**Yol 1 — tek komut (önerilen).** Başlat menüsünde "PowerShell" yazıp açın, şu satırı yapıştırıp Enter'a basın:

```powershell
irm https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.ps1 | iex
```

En son sürümü indirir, SHA-256 ile doğrular ve **kurulum sihirbazını** açar: klasörleri seçip **Kur**'a basın.
FerIDE "Ayarlar → Uygulamalar" listesine eklenir ve açılır. Zaten kuruluysa sihirbaz açılmaz; bulunduğu yerde
güncellenir.

**Yol 2 — elle.** [Sürümler](https://github.com/avciaytug/ProjectFerIDE/releases) sayfasında en üstteki sürümden
`feride-windows-x64.zip` dosyasını indirin, bir klasöre çıkarın ve `feride.exe`'yi çalıştırın: aynı kurulum
sihirbazı açılır. Kurmadan kullanmak isterseniz sihirbazdaki **Kurmadan, bu klasörden kullan (taşınabilir)**'ı seçin.
FerIDE henüz dijital olarak imzalı olmadığı için Windows "Bilgisayarınız korundu" uyarısı gösterebilir:
**Ek bilgi → Yine de çalıştır**'a tıklayın.

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.sh | bash
```

Masaüstü oturumunda kurulum sihirbazı açılır (klasör seçimi Windows'takiyle aynı). SSH/sunucu gibi masaüstü
olmayan oturumlarda sihirbaz açılmaz, varsayılan konumlara kurulur. Ya da
[Sürümler](https://github.com/avciaytug/ProjectFerIDE/releases) sayfasından `feride-linux-x64.tar.gz` /
`feride-macos-arm64.tar.gz` dosyasını indirip açın ve `feride`'yi çalıştırın. Linux'ta pencere için WebKitGTK gerekir
(betik eksikse tek bir `sudo` onayıyla kurar). macOS'ta elle indirdiyseniz: `xattr -dr com.apple.quarantine feride`.

### Sihirbazsız (otomatik) kurulum

Klasörler ortam değişkenleriyle verilirse sihirbaz açılmaz:

```powershell
$env:FERIDE_INSTALL_DIR = 'D:\FerIDE'; $env:FERIDE_DATA_DIR = 'D:\FerIDE-Veri'
irm https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.ps1 | iex
```

```bash
curl -fsSL https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.sh \
  | FERIDE_INSTALL_DIR=/mnt/disk2/feride FERIDE_DATA_DIR=/mnt/disk2/feride-veri bash
```

`FERIDE_NO_SHORTCUTS=1` kısayol ve PATH eklemez, `FERIDE_NO_LAUNCH=1` kurulumdan sonra açmaz. Aynısı programın
kendisiyle de yapılabilir: `feride install --yes --dir D:\FerIDE --data D:\FerIDE-Veri`.

### İlk açılış

1. **Kurulum sihirbazı** açılır ve bilgisayarınızı tarar. **Seçilenleri kur**'a basın: llama.cpp (model motoru),
   uv, Node.js ve gerekiyorsa taşınabilir Git kurulur (birkaç dakika).
2. **Model indirin:** soldaki çubukta **Model Merkezi** → arama kutusuna yazmaya başlayın (ör. `qwen3`, `gemma`) →
   bir depo seçin → genellikle **Q4_K_M** dosyasını indirin → **Başlat**. FerIDE belleği ölçer ve modeli GPU'ya,
   GPU + RAM'e ya da işlemciye kendisi yerleştirir. Kabaca: 16 GB RAM → 4–8B modeller, 32 GB → 14B ya da 30B-A3B
   (MoE), 64 GB ve üstü → daha büyük modeller.
3. Sağdaki panelden **Feride ile yazışın**. Mesaj kutusunun altından düşünmeyi açıp kapatabilir, model ve izin modu
   seçebilirsiniz.
4. **Sesli sohbet (isteğe bağlı):** Ayarlar → Ses → **Kur** (~4,4 GB; konuşma tanıma, Feride'nin sesi). Ardından
   mesaj kutusundaki **Canlı** düğmesi ya da `Ctrl+Shift+V`.

### Güncelleme ve kaldırma

- **Güncelleme:** kurulum komutunu yeniden çalıştırın; FerIDE bulunduğu yerde güncellenir, ayarlar, modeller ve
  sohbetler korunur.
- **Kaldırma** (üç yoldan biri):
  - **Windows:** Ayarlar → Uygulamalar → Yüklü uygulamalar → **FerIDE** → **Kaldır**.
  - **FerIDE içinden:** Ayarlar → Genel → Kurulum → **FerIDE'yi kaldır…**
  - **Komut satırı:** `feride uninstall` (Linux'ta uygulama menüsünde FerIDE'ye sağ tıklayıp **FerIDE'yi kaldır**).

  Program, kısayollar, PATH girdisi ve "Uygulamalar" kaydı silinir. Modeller ve sohbetler varsayılan olarak
  **yerinde kalır** (yeniden kurunca kaldığınız yerden devam edilir); kaldırırken "verileri de sil" seçilirse
  (`feride uninstall --purge`) yalnızca FerIDE'nin oluşturduğu dosyalar silinir, veri klasörüne sizin koyduğunuz
  başka dosyalara dokunulmaz.

### Sorun giderme

- **"llama-server.exe — Bozuk Görüntü … 0xc0e90002" hatası (Windows 11):** Windows'un *Akıllı Uygulama Denetimi*
  (Smart App Control) açık ve dijital olarak imzalanmamış programları engelliyor; FerIDE'nin model motoru llama.cpp
  henüz imzalı değil. **Windows Güvenlik → Uygulama ve tarayıcı denetimi → Akıllı Uygulama Denetimi ayarları →
  Kapalı** yapın ve FerIDE'yi yeniden başlatın. FerIDE bu durumu kendisi de algılayıp açıklar. Windows'un Nisan 2026
  ve sonraki güncellemelerinde bu ayar sonradan yeniden açılabilir.
- **Windows'ta Linux komutunu (`curl … | bash`) çalıştırdıysanız:** betik Windows'u algılayıp Windows kurulumuna
  geçer; yine de Windows'ta PowerShell komutunu kullanın.
- **Tanı:** `feride doctor` bağımlılıkları, donanımı, modelleri ve Akıllı Uygulama Denetimi durumunu gösterir.
  Günlükler: `~/.feride/logs/`.

### Gizlilik

Modeller, konuşma tanıma ve ses tamamen bu bilgisayarda çalışır; sohbetleriniz hiçbir sunucuya gönderilmez.
İnternet yalnızca kurulumda, model indirirken ve ajandan web araması / sayfa okuma istediğinizde kullanılır.

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
| `feride install [--dir D] [--data D] [--yes]` | Kurulum sihirbazı; `--yes` ile sormadan kurar (`--no-shortcuts`, `--no-path`, `--no-launch`) |
| `feride uninstall [--purge] [--yes]` | Kaldırır; `--purge` modelleri ve sohbetleri de siler |

## Veri klasörü

Varsayılan `~/.feride` (Windows: `%USERPROFILE%\.feride`, v5.3.8 ile aynı); kurulumda başka bir sürücü ya da
klasör seçilebilir. Seçim program klasöründeki `install.json`'da saklanır; `FERIDE_HOME` ortam değişkeni her
ikisinin de önüne geçer. Kullanılan klasör Ayarlar → Genel'de ve `feride doctor`'da görünür.

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
