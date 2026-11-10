# Sürüm notları

## beta v5.4 (5.4.0-beta.2) — Canlı sesli sohbet

### Yeni
- **Canlı sesli sohbet** (Gemini Live / ChatGPT sesli mod benzeri): mesaj kutusundaki **Canlı** düğmesi ya da `Ctrl+Shift+V`.
  Konuşmaya başladığını kendisi algılar, susunca yazıya çevirip gönderir, yanıtı model yazarken cümle cümle
  seslendirir ve yeniden dinlemeye geçer. Tamamen yerel: konuşma algılama arayüzde, Whisper ve Türkçe ses FerIDE'nin
  ses sunucularında.
  - **Araya girme:** Feride konuşurken konuşmaya başlarsan susar ve görevi durdurur (kapatılabilir; hoparlör sesi
    mikrofona kaçıyorsa kulaklık önerilir). Küreye dokunmak ya da `Boşluk` da susturur; `M` mikrofonu kapatır.
  - **Sesle onay:** ajan bir işlem için onay isterse "evet" / "hayır" demek yeterli.
  - Sesli turlarda ajan kısa, konuşma diliyle yanıt verir; kod blokları okunmaz, ekranda gösterilir.
  - İlk turdan sonra konuşmanın bitişinden ilk sesli yanıta ~1,5 sn (Qwen3.8-35B-A3B, Strix Halo).
- **Düşünme aç/kapat** mesaj kutusunun altında: düşünebilen modellerde (Qwen3, Gemma 4 …) akıl yürütmeyi tek tıkla açar.
- **Model seçici** mesaj kutusunun altında: yerel modeller boyut, kuantizasyon ve görsel desteğiyle listelenir;
  seçilen model hemen yüklenir. Modeli durdurma ve Model Merkezi'ne geçiş de buradan.
- **Token ve hız bilgisi:** her yanıtın altında girdi (bağlam) ve çıktı tokenları, ortalama üretim hızı (token/sn) ve
  süre; ayrıntıda istem işleme hızı, önbellekten gelen tokenlar ve model adımı sayısı. Mesaj kutusunun altında son
  turun özeti ve bağlam doluluğu. Bilgiler sohbet geçmişinde saklanır.
- **Model Merkezi'nde canlı arama:** yazmaya başlar başlamaz bu bilgisayardaki eşleşen modeller ve Hugging Face'teki GGUF
  depoları listelenir; eşleşen kısımlar vurgulanır.

### İyileştirmeler ve düzeltmeler
- Ses paketine **Whisper small** eklendi: Türkçe konuşma tanıma base modele göre belirgin biçimde daha doğru.
- "Sesle yaz" kaydı 16 kHz WAV olarak gönderiliyor; ffmpeg kurulu olmayan Windows'ta da yazıya çevriliyor (WebM çözülemiyordu).
- Bir görev hatayla bittiğinde hata mesajı, sohbet yeniden yüklenince kayboluyordu; artık kalıcı.
- Masaüstü penceresi kapatılırken oluşan "cannot move state from Destroyed" çökmesi giderildi.
- Model sunucusu beklenmedik şekilde kapanırsa son günlük satırları `logs/feride.log`'a yazılıyor (yeniden başlatmada kaybolmuyor).
- Uzak uç noktalarda (Ollama, LM Studio, vLLM …) üretim hızı akış süresinden hesaplanıyor.
- macOS: izin denetiminde geçici klasörler (`/var/folders`) artık hassas sayılmıyor; CI üç platformda.

## beta v5.4 (5.4.0-beta.1) — Rust'a geçiş

FerIDE baştan yazıldı. Flutter + Dart + Python yerine tek bir Rust programı: çekirdek, yerel sunucu ve WebView arayüz.

### Mimari
- **Rust çekirdek** (`feride-core`): model yönetimi, ajan, araçlar, izinler, MCP, skill, hafıza, kurulum.
- **Tek çalıştırılabilir dosya** (`feride.exe` / `feride`): masaüstü penceresi, başsız sunucu (`feride serve`), tanı (`feride doctor`), kurulum (`feride setup`).
- **Arayüz** WebView'de (Windows: WebView2) çizilir; arayüz çökse de ajan ve model çalışmaya devam eder.
- Veri klasörü değişmedi (`~/.feride`): modeller, skill'ler, MCP ayarları ve llama.cpp kurulumu olduğu gibi kullanılır; v5.3.8 hafıza kayıtları otomatik taşınır.

### Windows'ta düzeltilen sorunlar
- Ajan komutları **Git Bash** ile çalışıyor (modellerin yazdığı bash komutları artık hata vermiyor). Git yoksa taşınabilir sürümü kullanıcı klasörüne kuruluyor.
- FerIDE kapanınca/çökünce **llama-server, MCP ve ses sunucuları da kapanıyor** (İş Nesnesi). GPU belleği ve portlar açık kalmıyor.
- `npx`, `uvx` gibi `.cmd` komutları doğru çalıştırılıyor: MCP sunucuları Windows'ta başlıyor.
- Python alt süreçleri UTF-8'e zorlanıyor; Türkçe karakterler MCP/JSON akışını bozmuyor (v5.3.8'de cp1254 yüzünden kopuyordu).
- Konsol pencereleri yanıp sönmüyor; her ses cümlesi ve ölçüm için PowerShell açılmıyor.
- **llama.cpp kurulumu yeniden çalışıyor**: derlemeler artık "ön sürüm" yayınlanıyor; v5.3.8'in kullandığı `releases/latest` adresi derleme döndürmüyordu.
- `feride.exe` C çalışma zamanını statik içeriyor; VC++ kurulu olmayan bilgisayarda da açılıyor.

### Kurulum
- İlk açılışta **kurulum sihirbazı**: llama.cpp (Vulkan/CUDA/HIP/CPU/Metal), Git + Git Bash, uv, Python belge stüdyosu, ses paketi, Node.js, WebView2, VC++ çalışma zamanı.
- Her şey kullanıcı klasörüne kurulur. Yönetici gerektiren işler (VC++ çalışma zamanı, uzun dosya yolları; Linux'ta sistem paketleri) **tek betikte, tek onayla** yapılır ve bir daha sorulmaz.
- İndirmeler doğrulanır (Node.js SHA-256, Hugging Face LFS SHA-256); arşivden dışarı yazma (zip slip) engellenir.

### Ajan
- Araçlar: `read_file`, `write_file`, `edit_file` (CRLF toleranslı), `list_directory`, `glob`, `grep`, `run_command` (arka plan desteği), `process`, `web_search`, `fetch_url`, `todo_write`, `use_skill`, `save_skill`, `remember`, `recall`, `spawn_agent` (keşif/genel alt ajan), `read_document`, `edit_document`, `open_in_system` ve tüm MCP araçları.
- **Plan modu** (salt okunur) eklendi; izin modu görev sürerken değiştirilebilir.
- **Kontrol noktaları:** ajanın değiştirdiği her dosyanın önceki hali saklanır; sohbetten tek tıkla geri alınır.
- **Bağlam sıkıştırma:** bağlam dolunca eski araç çıktıları kısaltılır, gerekirse eski konuşma modelin yazdığı özetle değiştirilir.
- Proje talimatları: çalışma alanındaki `FERIDE.md` / `AGENTS.md` / `CLAUDE.md` otomatik okunur.
- Onay kartında dosya değişikliğinin farkı (diff) gösterilir; reddederken ajana not yazılabilir.
- Döngü tespiti, görsel girdi (mmproj), düşünme modu, yerel olmayan OpenAI uyumlu uç nokta desteği.

### Güvenlik
- Yerel sunucu yalnızca `127.0.0.1`'i dinler; her açılışta yeni jeton, `Origin` denetimi, sıkı CSP.
- Yıkıcı komut listesi Windows komutlarıyla genişletildi (`format`, `diskpart`, `vssadmin delete`, `bcdedit`, `rd /s C:\` …).
- Ajan FerIDE'nin kendi ayar/sır dosyalarını değiştiremez; `.ssh`, `.aws`, başlangıç klasörleri her modda onaya tabi.
- Yerel ağ / loopback adreslerine istek her modda onaya tabi (SSRF); yönlendirmeyle yerel ağa geçiş engellenir.
- Web, belge ve MCP çıktıları modele `<untrusted_content>` olarak verilir (istem enjeksiyonuna karşı).
- API anahtarları Windows'ta DPAPI ile şifreli saklanır, arayüze geri gönderilmez.
- Markdown DOMPurify ile temizlenir; dış bağlantılar sistem tarayıcısında açılır.

### Arayüz
- Gezgin (git durumu), arama, CodeMirror düzenleyici, gerçek terminal (ConPTY), model günlüğü, arka plan işlemleri.
- Ajan paneli: akışlı yanıt, düşünce, araç kartları, onaylar, yapılacaklar, görsel ekleme, sesle yazma, sesli yanıt.
- Model Merkezi: yerel modeller, bellek planı önizlemesi, Hugging Face arama ve devam ettirilebilir indirme, görsel adaptörü eşleştirme.
- Ayarlar: izin modu, kabuk, MCP sunucuları, skill'ler, hafıza, ses. Koyu/açık tema, sohbet odak modu.

### Kaldırılanlar
- Flutter, Dart ve derleme gereksinimleri (Flutter SDK, Visual Studio) — son kullanıcıya gerekmiyor.
- `relay8` (USB röle denemeleri) ana projeden çıkarıldı.

### Bilinen eksikler (5.5'e)
- Ses hâlâ isteğe bağlı Python sunucularıyla çalışıyor; sherpa-onnx ile süreç içine taşınacak (yankı engelleme, sesle söz kesme).
- Ekran görüntüsü aracı (`take_screenshot`) henüz taşınmadı.
- İşletim sistemi düzeyinde korumalı alan (AppContainer / bubblewrap), imzalı paketler ve otomatik güncelleme.
