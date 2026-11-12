# Sürüm notları

## beta v5.4 (5.4.0-beta.10) — Model yeniden GPU'da çalışıyor

- **GPU algılama düzeltildi:** model başlatılırken GPU listesi bir kerelik boş gelirse (sürücü o an meşgulken)
  FerIDE "GPU yok" deyip modeli işlemcide başlatıyordu: 27B modelde ~3,5 token/sn. Artık liste birkaç kez, arada
  beklenerek yeniden sorulur; bu bilgisayarda daha önce GPU görüldüyse boş liste "GPU yok" sayılmaz. Aynı model
  Radeon 8060S'te tamamen GPU'da ~11 token/sn. Başarısız denemeler günlüğe yazılır.
- **Yarım kalan llama.cpp kurulumu:** arşiv açıldıktan sonra klasör yerine taşınamazsa (Windows'ta virüs taraması
  yeni dosyaları birkaç saniye kilitleyebilir) kurulum yarım kalıyordu. Taşıma artık yeniden denenir, olmazsa
  kopyalanır; daha önce yarım kalmış kurulum FerIDE açılırken kendiliğinden tamamlanır.
- **Kurulum betikleri en yeni sürümü seçiyor:** GitHub sürüm listesini ada göre sıraladığı için `install.ps1` /
  `install.sh` beta.10 yerine beta.9'u indiriyordu; artık yayın tarihine göre seçiliyor.

## beta v5.4 (5.4.0-beta.9) — Kurulum yerini seçme, kaldırıcı (beta.8'in tamamlanmış hâli)

beta.8'in derlemesi yarım kalmıştı (yalnızca Linux paketi yayınlandı ve onda `feride uninstall` çalışmıyordu). Bu
sürüm beta.8'deki her şeyi içerir, ek olarak:

- **Linux'ta kaldırma düzeltildi:** kaldırıcı kendi iş parçacığını "çalışan başka bir FerIDE" sanıp kapatıyordu.
- Klasör karşılaştırmaları macOS'ta `/var` ↔ `/private/var`, Windows'ta kısa (8.3) klasör adlarıyla da doğru çalışıyor.

## beta v5.4 (5.4.0-beta.8) — Kurulum yerini seçme, kaldırıcı, işletim sistemine uygun komutlar

### Kurulum
- **Kurulum sihirbazı:** FerIDE artık nereye kurulacağını soruyor. **Program klasörü** ve **veri klasörü** (modeller,
  llama.cpp, ses paketi, sohbetler, ayarlar) ayrı ayrı seçilir: C:, D: ya da herhangi bir klasör; Linux'ta herhangi bir
  disk bölümü (`/mnt/...`). Sihirbaz sürücüdeki boş alanı gösterir, seçilen klasördeki mevcut FerIDE verilerini tanır,
  sürücü kökü / ev / sistem klasörlerini reddeder. Kısayollar ve komut satırından çalıştırma isteğe bağlıdır.
  **Kur**'a basılana kadar diske hiçbir şey yazılmaz.
- Kurulum betikleri (`install.ps1`, `install.sh`) paketi doğruladıktan sonra sihirbazı açar; FerIDE zaten kuruluysa
  bulunduğu yerde sessizce güncellenir. `FERIDE_INSTALL_DIR` / `FERIDE_DATA_DIR` ile sihirbazsız kurulum; masaüstü
  oturumu olmayan Linux'ta varsayılan konumlar. Betik sonunda kurulan klasörleri yazar.
- İndirilen `feride.exe` doğrudan çalıştırıldığında da sihirbaz açılır; istenirse **Kurmadan, bu klasörden kullan
  (taşınabilir)**.
- Veri klasörü program klasöründeki `install.json`'dan okunur (`FERIDE_HOME` > `install.json` > `~/.feride`).
- Eski betikle kurulmuş FerIDE'ler bu sürüme güncellenince kendiliğinden kayda geçer ("Uygulamalar" listesine eklenir).

### Kaldırma
- **FerIDE artık kaldırılabiliyor:** Windows Ayarlar → Uygulamalar → **FerIDE** → **Kaldır**; FerIDE içinde Ayarlar →
  Genel → Kurulum → **FerIDE'yi kaldır…**; ya da `feride uninstall`. Linux'ta uygulama menüsünde "FerIDE'yi kaldır".
- Program, kısayollar, PATH girdisi ve kaldırma kaydı silinir. Modeller ve sohbetler isteğe bağlı silinir
  (`--purge`); silinirken yalnızca FerIDE'nin oluşturduğu dosyalar silinir, veri klasörüne sizin koyduğunuz dosyalara
  dokunulmaz ve listelenir. Çalışan FerIDE ve motorları önce kapatılır.
- Kullanıcı PATH'i ham hâliyle düzenlenir: `%DEĞİŞKEN%` girdileri, değer türü ve diğer girdiler korunur.

### Ajan
- **Windows'ta Linux komutu çalıştırma düzeltildi.** Ajan `sudo`, `apt`, `systemctl`, `ps aux`, `ifconfig`,
  `xdg-open` gibi bu bilgisayarda olmayan komutları çalıştırmaya kalkarsa komut hiç çalıştırılmaz; Windows karşılığı
  (winget, Get-Service, tasklist/taskkill, ipconfig, netstat, open_in_system…) söylenip komutu yeniden yazması istenir.
  Linux/macOS'ta Windows'a özgü komutlar için de aynısı geçerli. "command not found" / "tanınmıyor" hatalarına da ipucu
  eklenir; sistem istemi her kabuk için olmayan komutları ve karşılıklarını listeler.

## beta v5.4 (5.4.0-beta.7) — Sadeleştirme

- Sol çubuktaki **Ara** paneli (büyüteç) ve `Ctrl+Shift+F` kısayolu kaldırıldı. Çalışma alanında arama gerektiğinde
  Feride'den istemek yeterli (ajanın kendi arama araçları değişmedi); dosya içinde arama düzenleyicide `Ctrl+F` ile.
- Karşılama sayfasındaki kısayollara canlı sesli sohbet (`Ctrl+Shift+V`) eklendi.

## beta v5.4 (5.4.0-beta.6) — Ses paketi yeni bilgisayarlarda kuruluyor

- **Ses paketi kurulumu düzeltildi:** Piper'ın Türkçe "fahrettin" sesi 30.12.2025'te ses sahiplerinin isteğiyle Piper
  deposundan kaldırıldığı için indirme 404 veriyor ve ses paketi yeni bilgisayarlarda hiç kurulamıyordu.
- **Feride'nin sesi (Ahenk Cep) artık kurulumla iniyor:** model dosyaları daha önce yalnızca eski v5.3.8 kurulumundan
  taşınabiliyordu; yeni bilgisayarlarda kadın sesi hiç yoktu. Resmi depodan (ozgurguler/ahenk-cep-tr, CC BY 4.0)
  sabit bir sürüm indirilir ve SHA-256 ile doğrulanır.
- **Erkek ses Piper DFKI'ye geçti** (veri kümesi CC BY-NC-SA 4.0) ve isteğe bağlı oldu: inemezse ses paketi yine de
  kurulur. Eski kurulumlarda yerelde kalmış fahrettin dosyası yalnızca DFKI yoksa kullanılır.
- Ses paketi sürümü 4: yarım kalmış ya da eski kurulumlarda Ayarlar > Ses'te **Güncelle** çıkar.

## beta v5.4 (5.4.0-beta.5) — Windows Akıllı Uygulama Denetimi uyumu, kurulum düzeltmeleri

### Windows
- **Akıllı Uygulama Denetimi (Smart App Control) tanınıyor.** Yeni Windows 11 kurulumlarında açık gelen bu özellik
  dijital olarak imzalanmamış programları engeller; llama.cpp "Bozuk Görüntü (0xc0e90002)" hatasıyla açılamıyordu ve
  FerIDE her denemede yeni bir hata penceresi açtırıyordu. Artık:
  - Denetim açıksa FerIDE açılışta, kurulum sihirbazında, model başlatma hatasında ve `feride doctor`'da nedenini ve
    çözümünü açıklar; **Windows Güvenlik'i aç** düğmesi doğrudan ilgili sayfaya götürür.
  - llama.cpp bir kez engellenince o oturumda yeniden çalıştırılmaz (pencere yağmuru biter); donanım ölçümü ve
    bayrak tespiti de onu çağırmaz.
  - Alt süreçlerde Windows hata pencereleri kapatılır; hata çıkış koduna dönüşür ve açıklanır.
  - Ses sunucuları engellenip hemen kapanırsa 60 sn beklenmez.
- Kurulum betiği, denetim açıksa kurulumdan sonra uyarır.

### Kurulum
- **Windows tek komutlu kurulumu düzeltildi:** SHA-256 özet dosyası yanlış okunduğu için kurulum herkeste
  "İndirme doğrulanamadı" hatasıyla duruyordu.
- `install.sh` Windows'ta (Git Bash, ya da PowerShell'den `| bash` ile WSL) çalıştırılırsa Windows kurulumuna geçer.
- Sürüm sayfalarında kurulum talimatı ve değişiklik notları.

## beta v5.4 (5.4.0-beta.4) — Ekran kartında konuşma tanıma

### Konuşma tanıma
- **Varsayılan artık en doğru model (Whisper large-v3-turbo).** Gerçek konuşmada small modeli, güveni yüksek
  görünse de Türkçede hata yapıyordu ("beni duyabiliyor musun" → "benim diyebiliyor musun"). Eski "otomatik"
  ayarı kendiliğinden en doğru modele geçer; hızlı model Ayarlar > Ses'ten seçilebilir.
- **GPU'da konuşma tanıma:** whisper.cpp, FerIDE'nin kendi CI'ında Vulkan (Windows, Linux) ve Metal (macOS) desteğiyle
  derlenir; ses paketi bunu ve ggml turbo modelini SHA-256 doğrulamasıyla kurar. Ekran kartı varsa tanıma orada
  yapılır; yoksa ya da hata olursa işlemcideki faster-whisper'a düşülür. Hangi motorun kullanıldığı
  `logs/feride.log`'a, whisper.cpp çıktısı `logs/whisper_server.log`'a yazılır.
- Ses paketi sürümü 3: eski kurulumlarda Ayarlar > Ses'te **Güncelle** çıkar (kurulu parçalar yeniden inmez).

### Arayüz
- Üst çubuktaki model göstergesi kaldırıldı (model seçici mesaj kutusunun altında).
- İzin modu (Plan / Sor / Düzenlemelere izin ver / Tam otonom) mesaj kutusunun altına taşındı.

### Gizlilik
- Konuşma tanıma, ses ve modeller çalışırken internete çıkmaz; her şey bu bilgisayarda çalışır. İnternet yalnızca
  kurulumda, model indirirken ve ajanın web araması / sayfa okuma araçlarında kullanılır.

## beta v5.4 (5.4.0-beta.3) — Daha iyi Türkçe anlama, Feride'nin sesi, hızlı model başlatma

### Konuşma tanıma
- **Mikrofon sinyali düzeltildi:** bazı dahili mikrofonlar (ör. AMD SoundWire) sinyale DC kayması ekliyordu; konuşmanın
  bittiği algılanamıyor (30 sn'lik kayıtlar), Whisper'ın VAD'ı da kaydı bütünüyle atıyordu. Artık 80 Hz yüksek geçiren
  süzgeç, ses düzeyi normalleştirme ve konuşmanın tepe düzeyine göre ayarlanan sessizlik algılama var; canlı sohbette
  kayıt zaten arayüzde ayrıldığı için sunucudaki ikinci VAD kapalı.
- **Whisper large-v3-turbo** eklendi (Türkçede çok daha doğru). "Otomatik" kip: önce hızlı model (small, ~1 sn);
  sonuçtan emin değilse turbo ile yeniden çevirir (~3 sn). Sesle yazma doğrudan turbo kullanır.
  Ayarlar > Ses > Konuşma tanıma'dan Hızlı / En doğru seçilebilir.
- STT sunucusu girişin süresini, düzeyini ve DC kaymasını günlüğe yazar (`logs/stt_server.log`).

### Ses
- **Feride'nin kadın sesi (Ahenk Cep) varsayılan olarak çalışıyor.** Gerekli paketler (`ema-lightning`, `trnorm`)
  ses paketine eklendi; v5.3.8'den beri eksik oldukları için ses sessizce erkek sese düşüyordu. Kadın sesi yüklenemezse
  canlı sohbet bunu açıkça söyler. Eski ses paketlerinde Ayarlar > Ses'te **Güncelle** düğmesi çıkar.

### Hız
- **Model başlatma 40 sn hızlandı:** GGUF başlığı okunurken her tokenizer kelimesi için 1 MB'lık tampon yeniden
  dolduruluyordu (Gemma 4'te 40 sn). Plan artık 0,1–0,5 sn.
- **Sohbet turları önbellekten devam ediyor:** sistem istemi her turda değiştiği için (saat, hafıza araması, araç sırası)
  model ~8K tokenı her mesajda baştan işliyordu. İstem artık oturum boyunca sabit; sesli sohbette ikinci turdan itibaren
  yanıt ~3 sn'de başlıyor (önce ~15 sn).
- **Ön ısıtma:** canlı sohbet açılınca model yüklenir ve sistem istemi önceden işlenir; ilk cümleye yanıt beklemeden gelir.

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
