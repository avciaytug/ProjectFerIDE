# FerIDE inceleme ve yenileme raporu

## v5.3.8 — Büyük modellerde çökme, GPU/CPU seçimi, skill ve MCP onarımları

### Büyük model (GLM-4.5-Air) çökmesinin kök nedeni
- **GPU belleği sınırı.** AMD Strix Halo'da GPU, Linux'un varsayılanı yüzünden 128 GB'ın yalnızca **62,5 GiB**'ını kullanabiliyor (`ttm.pages_limit`).
- **Model + bağlam sınırı aştı.** GLM-4.5-Air Q4_K_S'nin ağırlıkları 62,4 GiB. Uygulama buna 131.072 token bağlam (≈12 GiB KV) ekliyor ve yalnızca birkaç GiB pay bırakıyordu.
- **Zincirleme çöküş.** GPU belleği tükenince masaüstü, Chrome ve FerIDE'nin kendisi de GPU belleği alamayıp çöktü. Çekirdek logunda `bind failed: -ENOSPC` ve `Not enough memory for command submission`; 10:22–10:32 arasında FerIDE, Chrome ve llama-server için çökme dökümleri var.
- **Çift başlatma.** Ek olarak model iki kez üst üste başlatılabiliyordu. Bu sabah başka bir oturumda yapılan düzeltmeler (`--fit`, çift başlatma kilidi) korundu ve üzerine kuruldu.

### Bellek-farkında model başlatıcı (yeni)
- **`gguf_info.dart`.** Model dosyasının yalnızca başlığını okur (≈20 ms). Mimari, katmanlar, MoE uzman boyutu ve KV ihtiyacını çıkarır. Kayan pencereli (Gemma 4), karma/recurrent (Qwen3.5/3.8) ve MTP katmanlı (GLM) modelleri doğru hesaplar; ilk tahminde Gemma 4 için 51 GiB çıkan KV, gerçekçi değerine (1,6 GiB) indi.
- **`hardware_probe.dart`.** RAM, fiziksel çekirdek ve GPU belleğini llama-server'ın kendi `--list-devices` çıktısından ölçer (Vulkan/CUDA/ROCm/Metal). Paylaşımlı belleği (APU, Apple Silicon) tanır. Kurulu llama.cpp'nin **desteklediği seçenekleri** `--help`'ten okur; sürüm farkları kırılmaya yol açmaz (bu sürümde `--no-mmap` → `--load-mode none` olmuştu).
- **`model_launch_planner.dart`.** Seçilen moda göre yerleşimi ve bağlamı belirler, masaüstü için güvenli pay bırakır (paylaşımlı bellekte ≥8 GiB). Sığmayan yapılandırmayı **başlatmaz**, nedenini ve çözümünü yazar.
- **Motor yöneticisi.**
  - Başlatma ve durdurma sıralı (aynı anda tek model).
  - Önceki model kapandıktan sonra ölçüm ve plan yapılıyor.
  - Linux'ta modele `oom_score_adj=800` veriliyor; RAM biterse çekirdek önce modeli kapatır, masaüstünü değil.
  - Yükleme süresi model boyutuna göre bekleniyor.
  - Çökme nedeni Türkçe açıklanıyor; yüklemeden sonra GPU'da ölçülen bellek gösteriliyor.

### Ayarlar > Genel > Model Çalıştırma (yeni)
- **Otomatik** (önerilen), **GPU offload** (tamamı GPU), **CPU offload** (MoE uzmanları RAM'de, kalanı GPU'da), **Yalnızca CPU**.
- Bağlam boyutu: Otomatik / 8K–128K.
- Donanım özeti, son plan, uyarılar.
- APU'larda GPU bellek sınırını yükselten komut (`scripts/gpu_bellek_ayari.sh`, sudo gerekir, geri alınabilir).

### GPU bellek sınırı betiği
- `sudo bash scripts/gpu_bellek_ayari.sh` sınırı "RAM − 12 GB"a (bu makinede 112 GiB) yükseltir.
- Ana GRUB dosyasına dokunmaz; `/etc/default/grub.d/` altına ayrı bir dosya ekler. Geri almak: `--geri-al`.
- **Bu makinede tespit edilen sorun:** `/etc/default/grub` dosyasının 1. satırının başında yanlışlıkla yazılmış "xx" var (bugün 10:50'de değiştirilmiş). Bu haliyle `update-grub` hata verip durur. Betik bunu tespit eder ve onayınızla, yedek alarak düzeltir.

### Gerçek donanımda doğrulama (bu makine, GLM-4.5-Air Q4_K_S, 67 GB)

| Mod | Yükleme | GPU'da kullanılan | GPU'da boş kalan | Hız | Çekirdek GPU hatası |
|---|---|---|---|---|---|
| Otomatik | 16 sn | 52,3 GiB (modelin ~%77'si, 32K bağlam) | 8,2 GiB | 16,1 token/sn | 0 |
| CPU offload | 33 sn | 18,4 GiB (tahmin: 18,6) | 42,3 GiB | 11,3–12,2 token/sn | 0 |
| GPU offload | — | Başlatılmadı: "64,3 GiB gerekiyor, GPU'da 52,5 GiB kullanılabilir" | — | — | — |

Aynı model üzerinde ajan uçtan uca çalıştırıldı:
- **Skill:** `systematic-debugging` kendiliğinden seçilip yüklendi (40 sn).
- **MCP sqlite:** tablo oluşturuldu, satır eklendi, sorgulandı (18 sn).
- **MCP fetch:** web sayfası çekildi (10 sn).
- **Alt ajan:** dosyaları saydı ve sonucu bildirdi (45 sn).

Kullanıcının uygulamada GLM, Huihui 27B ve Qwen 35B arasında yaptığı geçişler de çökmeden tamamlandı.

### Gerçek testlerin ortaya çıkardığı ek hatalar (düzeltildi)
- **`--no-mmap` → `--load-mode`.** llama.cpp `--no-mmap` seçeneğini kaldırmış; model hiç açılmıyordu. Artık kurulu sürümün desteklediği seçenekler `--help`'ten okunuyor. Eski sürümlerde `--no-mmap` ve hesaplanmış `-ngl` kullanılıyor.
- **Aynı modelin yeniden yüklenmesi.**
  1. Sunucu model kimliğini tam dosya yoluyla bildiriyor (bölünmüş modelde `…-00001-of-00002.gguf`), model listesi ise parça ekini atılmış adı kullanıyor.
  2. Yüklemeden sonra açılır menü yanlış modeli gösteriyordu; aynı model yeniden seçilince baştan yükleniyordu.
  3. Bu sabahki çift başlatmanın da muhtemel kaynağı buydu. Adlar artık normalleştiriliyor; aynı model yeniden seçilirse yükleme yapılmıyor.
- **Yanlış görüntü projektörü.** Qwen3.8-35B'ye 27B'nin mmproj dosyası eşleniyordu: ilk yükleme her seferinde başarısız oluyor, görüntü desteği kayboluyordu. Eşleştirme artık en uzun ortak ada ve parametre boyutuna (35b/27b/12b) göre yapılıyor.
- **`glob` aracı.**
  - `**/*.txt` kökteki dosyaları bulamıyordu.
  - `node_modules`, `build`, `.git` içindeki dosyalar sonuçlara giriyordu.
  - Parantez gibi karakterler kaçışlanmıyordu; Windows yol ayırıcısı desteklenmiyordu.
  - Doğru glob anlamıyla yeniden yazıldı.

### Skill'ler
- Diskten senkronizasyon fonksiyonu hiç çağrılmıyordu: `~/.feride/skills` altındaki **17 skill'in yalnızca 5'i** ajana görünüyordu. Artık açılışta senkronize ediliyor.
- Kayıt sorgusunda sütun kayması vardı: kullanım sayacına tarih, oluşturulma tarihine 0 yazılıyordu. Düzeltildi; eski kayıtlar otomatik onarılıyor.
- Tırnaklı ve çok satırlı YAML açıklamalar doğru okunuyor.
- `use_skill`, skill klasörünün yolunu ve ek dosyalarını da veriyor (ör. brainstorming → `visual-companion.md`, `scripts/`).

### MCP
- İstemci sağlam. Ancak varsayılan sunucular Node.js (`npx`) ve uv (`uvx`) istiyordu ve bunlar kurulu değildi; hiçbir sunucu çalışmıyor, uygulama da "Hazır" gösteriyordu.
  - Artık eksik çalışma ortamı sunucu başına gösteriliyor.
  - MCP sekmesinde "uv kur" düğmesi ve Node.js komutu var.
- Resmî `mcp-server-sqlite` arşivlenmiş ve güncel MCP/pydantic ile çalışmıyor (`'Server' object has no attribute 'list_resources'`).
  - FerIDE'ye yalnızca Python standart kütüphanesiyle yazılmış **yerleşik SQLite MCP sunucusu** eklendi.
  - Eski yapılandırma otomatik olarak buna taşınıyor.
  - Okuma araçları salt-okunur işaretli ve yıkıcı sorguları reddediyor.

---

## v5.3.7 — Feride'nin kadın sesi, ses seçimi ve Windows/macOS hazırlığı

**Kadın sesi (varsayılan): Feride — Ahenk Cep.** Tasarlanmış sentetik bir Türkçe kadın sesi; gerçek bir kişiye ait değil.
- 8,6M parametre, 48 kHz, tamamen yerel, CC BY 4.0.
- Ölçümler (bu makinede, işlemcide):
  - 3,6–5 saniyelik cümle 0,3–0,5 saniyede üretiliyor (gerçek zamandan 10–15 kat hızlı).
  - Whisper'a geri dinletildiğinde cümleler birebir anlaşılıyor.
  - Sayılar, saatler ve para birimleri doğal okunuyor ("14:30", "2.500 TL").
- Kurulum: `scripts/setup_voice.py`. Model dosyaları yayınlanmış SHA-256 özetleriyle doğrulanıyor; özet tutmazsa kurulmuyor. Bütün kurulum betiklerine bağlandı.

**Neden Piper kadın sesi değil?** Resmî Piper deposunda Türkçe kadın sesi yok. Ayrıca mevcut erkek ses (fahrettin), sahiplerinin talebiyle resmî depodan kaldırılmış; dağıtırken bu lisans durumu göz önünde bulundurulmalı.

**Tek ses sunucusu** (`scripts/tts_server.py`):
- Kadın ve erkek sesi birlikte sunuyor; istenen ses yoksa diğerine düşüyor.
- Flask bağımlılığı kalktı. Chunked istekleri de destekliyor.
- Dosya adlarını doğal okuyor ("rapor nokta PDF").
- Kaldırılanlar:
  - XTTS: Python 3.14'te çalışmıyordu.
  - Edge TTS: buluta bağlanıyordu, "tamamen yerel" ilkesine aykırıydı.
  - Her başlatmada arayüzü bloke eden XTTS denetimi.

**Ayarlar > Genel > Ses ve Konuşma:**
- Kadın / Erkek seçimi (varsayılan kadın).
- Konuşma hızı (0,8–1,3×).
- "Sesi dinle" önizlemesi.
- Kadın ses kurulu değilse uyarı.

**Akıcılık.** Bir cümle çalarken bir sonraki önceden sentezleniyor, cümleler arasındaki boşluk kalktı. Sesli asistanın akışı: "Feride, …" ile uyanma → komutu işleme → onayları sesle sorma → sözünü kesme.

**Gizlilik: ses bilgisayardan çıkmıyor (kanıtlandı).** TTS ve STT, ağ arayüzü olmayan izole bir Linux ağ alanında (`unshare -rn`) başlatıldı; internet erişimi doğrulanarak engellendi. Bu ortamda Feride kadın sesiyle konuştu ve Whisper cümleyi birebir yazdı. Ek güvenceler:
- Ses sunucularına çalışma anında `HF_HUB_OFFLINE=1` kilidi konuldu; modeller yalnızca kurulumda iner. Whisper "small" modeli artık kurulumda önceden indiriliyor; eskiden çalışma anında arka planda indirilmeye çalışılıyordu.
- Mikrofon sesi yalnızca `127.0.0.1` (bilgisayarın kendi içi) üzerinden VAD/STT'ye gider.
- İnternete yalnızca kullanıcının istediği şu işlemlerde çıkılır: ajanın `search_web` / `read_url_content` araçları (izin moduna tabi), Model Merkezi indirmeleri ve etkinleştirilen MCP sunucuları.

**Model Merkezi düzeltmesi.** Bölünmüş GGUF indirilirken (`…-00001-of-00002.gguf`) eşleştirme kodu boş bir anahtar üretiyordu; `"ad".contains("")` her zaman doğru olduğu için ilerleme çubuğu bütün kartlarda, yüklü modellerde bile görünüyordu. Eşleştirme kesinleştirildi:
- Arama kartları birebir depo adıyla eşleşiyor.
- Yerel kartlar normalize edilmiş dosya adıyla eşleşiyor.
- Ana penceredeki ikinci ilerleme çubuğu kaldırıldı.
- Testlerle doğrulandı.

**Windows/macOS.** Ayrıntılar `WINDOWS_MACOS.md` dosyasında.
- `kurulum.ps1` Windows PowerShell 5.1'de hiç çalışmıyordu (BOM'suz UTF-8'deki "—"). Düzeltildi; `.bat` dosyaları CRLF'e çevrildi.
- Windows kurulumu gerekirse Flutter, VS Build Tools ve Git'i kendisi kurup `.exe`'yi derliyor.
- Üç platformu bulutta derleyen bir GitHub Actions iş akışı eklendi.

---

## v5.3.6 — Sesli iletişim neden çalışmıyordu ve nasıl düzeltildi

Python ses servisleri (Piper TTS, Whisper STT) kendi başlarına kusursuzdu: ses üretimi 0,12 sn, deşifre 0,6 sn. Sorun bu servisleri birbirine bağlayan katmandaydı. Birbirine eklenen dört neden vardı:

| # | Neden | Sonuç | Düzeltme |
|---|---|---|---|
| S1 | **Mikrofon DC kayması.** Dahili AMD SoundWire mikrofonu sinyale sabit −0,23 ofset ekliyor; sessiz ortamda bile RMS 0,23 ölçülüyor. Canlı oturum VAD'ı yalnızca ham enerjiye bakıyordu. | VAD konuşmanın hiç bitmediğini sanıyordu: "speech_start" geldi, "speech_end" hiç gelmedi, deşifre yapılmadı, FerIDE yanıt vermedi. | Yeni VAD 300–3400 Hz konuşma bandına bakıyor (DC'ye ve uğultuya bağışık). Gürültü tabanını uyarlıyor ve tek bir konuşmayı en fazla 25 sn tutuyor (asla takılı kalmaz). STT de DC'yi temizliyor. |
| S2 | Sesli oturum Ollama'ya (11434) bağlanıyordu; Ollama kurulu değil. | Model hiç yanıt vermiyordu. | v5.3.5'te düzeltildi: aynı llama-server kullanılıyor. |
| S3 | Ses sunucusu "çalışıyor mu" kararı süreç adına (`pgrep`) göre veriliyordu. | Port boşken aynı adda başka bir süreç varsa VAD hiç başlatılmıyordu. Eski sürüm sunucular yenilenmiyordu. | Karar portu dinleyen sunucuya göre veriliyor. Betik değişince eski sunucu otomatik yenileniyor (sürüm parmak izi). |
| S4 | Canlı oturum ekranı, oturum kimliği ilk cümlede değiştiği için motor olaylarını kaçırabiliyordu. | Bazen yanıt metni ve sesi gelmiyordu. | Ekran yeniden yazıldı: oturum baştan oluşturuluyor, durum makinesi ile çalışıyor. |

Ek iyileştirmeler:
- Gerçek mikrofon seviyesine tepki veren küre.
- "Sözünü kes" (barge-in).
- Onay gerektiğinde sesli uyarı.
- Boştayken animasyon durduğu için sıfır CPU kullanımı.
- **Ctrl+M** her yerden sesli asistanı açar; başlıkta belirgin bir "Sesli Konuş" düğmesi var.
- İzin modu rozeti başlıkta her an görünür ve tek tıkla değiştirilebilir.
- TTS çalma `audioplayers`/GStreamer yerine işletim sisteminin yerleşik oynatıcısıyla yapılıyor (`pw-play`/`paplay`/`aplay`, `afplay`, SoundPlayer). Daha hafif, bir native bağımlılık eksik.
- Testler artık geliştirme makinesindeki gerçek ses sunucularını başlatıp öldürmüyor (`FERIDE_INTEGRATION=1` ile isteğe bağlı).
- Native Linux derlemesi (cmake/clang) başarıyla yapıldı.

### v5.3.6 eklemeleri: sesle onay
- **Eller serbest modu kaldırıldı.** Başlıktaki "Eller serbest" rozeti ve arka planda "Feride" uyandırma kelimesini dinleyen özellik çıkarıldı; sesli konuşma için Canlı Oturum (başlıktaki **Sesli Konuş** düğmesi veya Ctrl+M) kullanılıyor.
- **Sesle onay.** Bir işlem onay gerektirdiğinde Feride ne yapmak istediğini söyleyip sorar: "Evet / tamam / onaylıyorum" ya da "hayır / iptal / vazgeç". "Hayır, yapma" gibi ifadelerde olumsuzluk önceliklidir. Ekrandaki onay penceresi de aynı anda geçerlidir.
- **Mikrofon paylaşımı.** Sohbet mikrofonu ve sesli asistan aynı kaydediciyi çakışmadan paylaşıyor; her deşifre sahibine teslim ediliyor.
- **Kısa sözcükler.** "Evet", "Feride" gibi kısa sözcükler artık atılmıyor: VAD eşiği düşürüldü, kısa kayıtlar Whisper için sessizlikle dolduruluyor, Whisper'a "Feride" adı ipucu olarak veriliyor.
- **Testler.** Onay yorumlayıcı için birim testleri eklendi. Gerçek TTS → DC kaymalı mikrofon → VAD → STT → niyet hattı için entegrasyon testi eklendi (`FERIDE_INTEGRATION=1`).

---


Tarih: 06.11.2026 · Temel: FerIDE Beta v5.3.5 · Değişiklikler git ile izleniyor (`git log`, `git diff 8c1db19`)

## 1. Bulunan sorunlar

### Güvenlik (kritik)
| # | Sorun | Etki | Durum |
|---|---|---|---|
| G1 | Ajan **hiçbir onay almadan** her komutu çalıştırıyor, her dosyayı yazıyordu. `permissionModeProvider` tanımlıydı ama hiçbir yerde kullanılmıyordu. "Tam Otonom Mod" anahtarı yalnızca adım sayısını değiştiriyordu, açıklaması yanıltıcıydı. | Model `rm -rf ~` üretse çalışırdı | ✅ Gerçek izin katmanı eklendi |
| G2 | `read_url_content`, URL'yi doğrudan `curl`'e veriyordu: `file:///home/.../.ssh/id_rsa` gibi adreslerle yerel dosyalar okunabiliyordu. | Yerel dosya sızıntısı | ✅ Yalnızca http/https |
| G3 | Plan modu yalnızca bir talimattı; model yine de dosya yazabiliyordu. | Plan modunda değişiklik | ✅ Plan modunda yalnızca okuma araçları verilir |
| G4 | `ProcessManager.killAll()` → `pkill -f stt_server.py`: sistemdeki **tüm** eşleşen süreçleri öldürüyordu (başka FerIDE örneği, testler). | Başka süreçler kapanır | ✅ Yalnızca kendi başlattığı süreçler |

### Mantık hataları
| # | Sorun | Durum |
|---|---|---|
| M1 | Sesli canlı oturum `127.0.0.1:11434` (Ollama) adresine gidiyordu; bu makinede Ollama kurulu değil, bu yüzden sesli oturum modele ulaşamıyordu. | ✅ Sesli ve yazılı oturum aynı sunucuyu kullanıyor |
| M2 | Ollama/vLLM seçildiğinde model o porta başlatılıyor, ajan ise yine 8080'e bağlanıyordu. | ✅ API adresi seçilen motoru izliyor |
| M3 | "Sadece okuma yapılıyor" uyarısı, araç sonuçlarının **arasına** `user` mesajı ekliyordu. Bu `tool_calls → tool` sırasını bozuyordu, sunucu 500 hatası veriyordu. | ✅ Not, araç sonucuna ekleniyor |
| M4 | `args['offset'] as int` gibi dönüşümler: yerel modeller `"10"` gönderince tüm tur "Bağlantı Hatası" diye çöküyordu. | ✅ Güvenli argüman dönüştürücüler |
| M5 | Komut çıktısının son satırları kayboluyordu: süreç bitince akış aboneliği hemen iptal ediliyordu. | ✅ Akış sonuna kadar okunuyor |
| M6 | MCP sunucusu her çağrıda yeniden başlatılıyordu; `memory` gibi durum tutan sunucular her seferinde sıfırlanıyordu. Model araç şemalarını hiç görmüyordu (`tools/list` yoktu), araç adlarını tahmin ediyordu. | ✅ Kalıcı bağlantı, araçlar yerel araç olarak sunuluyor |
| M7 | MCP sürecinin stderr çıktısı okunmuyordu; çok log yazan sunucularda boru tamponu doluyor, sunucu kilitleniyordu. `which` komutu Windows'ta çalışmıyordu. | ✅ |
| M8 | Kullanıcı başka sohbete geçince, arka planda süren ajan **yanlış sohbetin** geçmişini kullanıyordu. | ✅ Motor kendi oturumunu yüklüyor |
| M9 | `dispatch_worker` bitince `run()` yeniden çağrılıyordu; süren bir koşu varsa ikisi aynı anda çalışıyordu. | ✅ Oturum başına sıralı kuyruk |
| M10 | 400 hatası her zaman "bağlam aşıldı" diye gösteriliyordu. | ✅ Sunucunun gerçek hata mesajı gösteriliyor |
| M11 | Qwen/Hermes'in `<tool_call>{"name":..}` JSON biçimi ayrıştırılmıyordu; yalnızca `<function=..>` biçimi tanınıyordu. | ✅ İki biçim de destekleniyor |

### Ölü ve tekrarlanan kod
- `agent_engine.dart` 1.733 satırdı; araçlar 450 satırlık `if/else` zinciriyle çalışıyordu. Aynı araç kodu `subagent_engine.dart` içinde ikinci kez kopyalanmıştı. `aegis_providers.dart` içinde de `spawn` ve `spawnAndWait` neredeyse aynıydı. **Hepsi tek bir araç sistemi ve tek bir döngüde birleştirildi.**
- Silinenler:
  - `tool_registry.dart`
  - `check_market` / `analyze_market` dalları ve `finance_*.py` betikleri (hiçbir zaman modele sunulmuyordu)
  - Docker/web model eşlemesi (`modelForLabel`, `baseUrlForModel`, `/v1-qwen`)
  - `liveApiUrlProvider`, `autonomousModeProvider`, `permissionModeProvider`
  - `unloadOllamaModels` ve kapanışta Ollama'ya giden istekler
  - `toggleGpuForLlm` takma adı
  - Kullanılmayan importlar
- `requirements.txt` dosyasından çıkarılanlar: tekrarlanan `duckduckgo_search` (ddgs ile aynı), artık kullanılmayan `yfinance` ve `pandas`.

## 2. Yeni mimari (sade ama güçlü)

```
lib/agent/
  llm_client.dart    OpenAI uyumlu akış istemcisi (llama.cpp, Ollama, LM Studio, vLLM)
                     yeniden deneme (503/5xx/429), satır içi tool_call ayrıştırma, görsel desteği tespiti
  tools.dart         AgentTool = şema + risk + çalıştırıcı. ToolExecutor: izin → çalıştır → kısalt
  permissions.dart   İzin modları, yıkıcı/hassas komut kuralları, onay köprüsü (ApprovalBroker)
  agent_loop.dart    model → araçlar → model döngüsü (ana ajan VE alt ajanlar aynı kodu kullanır)
lib/services/agent_engine.dart   Oturum/UI bağlantısı: prompt, geçmiş, olaylar (≈560 satır)
lib/aegis/subagent_engine.dart   Alt ajan = aynı döngü + kendi bağlamı (≈90 satır)
lib/services/mcp_service.dart    Kalıcı MCP oturumları (stdio + Streamable HTTP), tools/list, tools/call
lib/features/chat/approval_listener.dart  Onay penceresi
```

### İzin modları (Ayarlar > Genel > İzin Modu)
| Mod | Okuma | Çalışma alanında dosya yazma | Komut | İnternet |
|---|---|---|---|---|
| Her işlemde sor | serbest | sorar | sorar | sorar |
| Dosya düzenlemeye izin ver (varsayılan) | serbest | serbest | sorar | serbest |
| Tam otonom | serbest | serbest | serbest* | serbest |

\* `sudo`, `rm -r`, `git push --force`, paket kurma/kaldırma, `shutdown` gibi komutlar **her modda** sorulur. Disk silme, `mkfs`, `dd of=/dev/...` ve fork bomb gibi komutlar **her modda engellenir**. `~/.ssh`, `~/.bashrc` ve `/etc` gibi hassas yollara yazmadan önce de her zaman onay istenir.

### Yeni ve iyileştirilmiş araçlar
- `list_directory`
- `take_screenshot`: KDE Spectacle, GNOME, grim/scrot, macOS ve Windows'ta çalışır
- `read_file`: satır numaralı okuma
- `replace_file_content`: `replace_all` seçeneği
- `run_command`: `cwd` ve `timeout_seconds` parametreleri, çıkış kodu raporu
- MCP araçları `mcp__sunucu__araç` adıyla doğrudan sunuluyor

## 3. Doğrulama
- `flutter analyze`: 0 hata, 0 uyarı.
- `flutter test`: 63 test geçiyor. Bunların 19'u yeni çekirdek testleri:
  - izin kuralları
  - araç çağrısı ayrıştırma
  - sahte sunucuyla uçtan uca ajan döngüsü
  - gerçek alt süreçle kalıcı MCP bağlantısı
- `FERIDE_LIVE=1 flutter test test/live_model_test.dart`: yerel Qwen3.8-35B modeli CSV'yi okudu, en pahalı ürünü buldu ve sonucu dosyaya yazdı (3 adım, ≈7 sn).
- Linux release paketi yeniden üretildi ve açılıyor.

## 4. Kalan işler / öneriler
1. **Yerel derleme araçları eksik.** Native çalıştırıcıyı (C++) yeniden derlemek için şu komut gerekir:
   `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev`
   Bu sürümde Dart kodu AOT olarak derlendi ve 5.3.4'teki birebir aynı motor/eklentilerle paketlendi. Windows ve macOS paketleri o makinelerde `flutter build windows|macos` ile üretilmeli.
2. Sesli oturumda onay pencereleri şimdilik tıklama ister. "Evet/Hayır" ile sesli onay eklenebilir.
3. `ide_shell.dart` (3.200 satır) ve `agent_panel.dart` (1.360 satır) arayüz dosyaları hâlâ büyük. Davranış değişmeden parçalara ayrılması önerilir.
4. 183 adet `info` düzeyinde stil uyarısı var (`withOpacity` → `withValues`, `print` kullanımı). Bunlar işlevsel değil.
