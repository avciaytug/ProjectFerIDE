# FerIDE inceleme ve yenileme raporu

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

### v5.3.6 eklemeleri: eller serbest ve sesle onay
- **"Feride" uyandırma kelimesi.** Başlıktaki **Eller serbest** rozetiyle açılır. Açıkken "Feride, …" demek yeterli: sesli asistan kendiliğinden açılır ve komutu doğrudan işler. Yalnızca "Feride" denirse "Efendim, dinliyorum" diye yanıt verir. Whisper'ın duyma hatalarını ("Ferit", "Felida", "Feride'ye") tolere eder; isim cümlenin başında değilse uyanmaz. Mikrofon yalnızca bu mod açıkken dinlenir ve ses bilgisayardan dışarı çıkmaz.
- **Sesle onay.** Bir işlem onay gerektirdiğinde Feride ne yapmak istediğini söyleyip sorar: "Evet / tamam / onaylıyorum" ya da "hayır / iptal / vazgeç". "Hayır, yapma" gibi ifadelerde olumsuzluk önceliklidir. Ekrandaki onay penceresi de aynı anda geçerlidir.
- **Mikrofon paylaşımı.** Sohbet mikrofonu, sesli asistan ve uyandırma dinleyicisi aynı kaydediciyi çakışmadan paylaşıyor; her deşifre sahibine teslim ediliyor.
- **Kısa sözcükler.** "Evet", "Feride" gibi kısa sözcükler artık atılmıyor: VAD eşiği düşürüldü, kısa kayıtlar Whisper için sessizlikle dolduruluyor, Whisper'a "Feride" adı ipucu olarak veriliyor.
- **Testler.** Uyandırma ve onay yorumlayıcı için birim testleri eklendi. Gerçek TTS → DC kaymalı mikrofon → VAD → STT → niyet hattı için entegrasyon testi eklendi (`FERIDE_INTEGRATION=1`).

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
