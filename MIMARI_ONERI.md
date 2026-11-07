# FerIDE'yi baştan yazsaydım: ne, nasıl, neden?

Kısa cevap: **baştan yazmazdım. Çekirdeği arayüzden ayırarak adım adım yeniden yapılandırırdım.** Çalışan özellikleriniz (ses, ajan, MCP, dosya stüdyosu) ve verileriniz var. Ajan çekirdeğinin artık testleri de var. Sıfırdan yazmak bunları riske atar. Aşağıdaki öneriler, bu oturumlarda kodda bizzat bulduğum sorunlara dayanıyor.

## 1. Çekirdek ile arayüzü ayırırdım (en önemli değişiklik)

**Şimdi:** Ajan döngüsü, model yönetimi, MCP, skill'ler ve ses denetimi Flutter arayüzünün içinde, tek bir süreçte çalışıyor.

**Sorun:** Bu sabahki çökmede GPU belleği tükenince arayüz (Flutter, GPU ile çizer) de çöktü. Arayüz çökünce de çalışan ajan görevi, açık MCP oturumları ve sesli konuşma birlikte gitti.

**Yapacağım:** `feride-core` adında, arayüzü olmayan bir arka plan servisi kurmak. Bu servis yerel bir WebSocket/JSON-RPC uç noktası açar; Flutter yalnızca bir istemci olur.

**Neden:**
- **Hata yalıtımı:** Arayüz çökse de ajan işini bitirir.
- **Pencere kapalıyken çalışma:** Sistem tepsisinden "Feride, şunu yap" mümkün olur.
- **Çoklu istemci:** Aynı çekirdeğe terminal komutu (`feride "raporu özetle"`) ya da yerel ağdaki telefon bağlanabilir.
- **Test:** Arayüzsüz test çok daha kolay.

**Dil:** Çekirdeği Dart'ta tutardım (`dart compile exe` ile tek dosya). Bugün `lib/agent/` ve servisler zaten saf Dart ve testli. Rust daha güçlü bir korumalı alan verir ama tam bir yeniden yazım ister.

## 2. Model çalıştırma: tek karar noktası

**Şimdi (v5.3.8):** Bu sürümde bellek-farkında planlayıcı eklendi.

**Daha ileri:**
- Model başına kayıtlı ayar profilleri.
- Yükleme sırasında ilerleme (stderr'den katman sayısı).
- Model değiştirirken öncekini güvenle boşaltan bir zamanlayıcı.
- "Arka planda hazır bekleyen hızlı model + istekte yüklenen büyük model" düzeni (llama-server router modu).

**Neden:** Bugünkü çöküşlerin iki nedeni vardı ve ikisi de tek bir karar noktasının olmamasından doğdu: model, bağlam ve GPU belleği birbirinden habersiz ayarlanıyordu; aynı model de iki kez başlatılabiliyordu.

## 3. Ses: üç Python sunucusu yerine tek ses motoru

**Şimdi:** STT, TTS ve VAD üç ayrı Python sunucusu. Aralarında WebSocket ve HTTP geçişleri var.

**Yapacağım:** Tek bir ses süreci, mümkünse sherpa-onnx ile süreç içinde (C API, Dart bağlantısı var).
- Silero VAD (ONNX).
- Akışlı konuşma tanıma.
- **Yankı engelleme** (WebRTC APM).
- Akışlı TTS. Ahenk Cep de ONNX'e dönüştürülür.

**Neden:**
- Daha az gecikme ve daha az süreç.
- Python bağımlılığının ses tarafında kalkması (Windows/macOS kurulumunun en kırılgan kısmı).
- Yankı engelleme sayesinde Feride konuşurken **sözünü sesle kesebilmek**. Bugün bu yalnızca düğmeyle mümkün.

## 4. Ajan: olay günlüğü, korumalı alan, akıllı bağlam

**Olay günlüğü:**
- **Şimdi:** Sohbetler her token'da bütün JSON dosyası yeniden yazılarak saklanıyor.
- **Yapacağım:** Oturum başına salt-ekleme JSONL günlüğü.
- **Neden:** Uzun sohbetlerde disk yükü ve kayıp riski azalır, geri alma ve yeniden oynatma bedavaya gelir.

**Korumalı alan:**
- **Şimdi:** İzin katmanı var. Komutlar yine de kullanıcının tam yetkisiyle çalışıyor.
- **Yapacağım:** İşletim sistemi düzeyinde korumalı alan: Linux'ta bubblewrap, macOS'ta sandbox-exec, Windows'ta Job Objects/AppContainer.
- **Neden:** "İzin ver" denmiş bir komut bile yalnızca çalışma alanına yazabilsin.

**Bağlam yönetimi:**
- **Şimdi:** Uzun bağlam kırpılarak yönetiliyor.
- **Yapacağım:** Bağlam dolunca modelin kendi yazdığı bir özetle sıkıştırma.
- **Neden:** Ajan uzun işlerde ne yaptığını unutmaz.

**Kontrol noktaları:** dosya kopyası yerine oturum başına git benzeri anlık görüntüler.

## 5. Skill'ler: diskteki dosyalar tek doğru kaynak

**Şimdi:** Skill'ler veritabanına kopyalanıyordu ve senkronizasyon hiç çağrılmıyordu. Diskte 17 skill olduğu halde ajan yalnızca 5'ini görüyordu (v5.3.8'de düzeltildi).

**Yapacağım:**
- `SKILL.md` dosyaları (Anthropic Agent Skills biçimi) tek kaynak olur.
- Açılışta ve dosya değiştikçe (dosya izleyici) bellekte dizinlenir.
- Veritabanı yalnızca kullanım istatistiği tutar.

**Neden:** İki kopya olduğu sürece birbirinden kopar.

## 6. MCP: kutudan çıktığı gibi çalışan

**Şimdi:** İstemci sağlam ama varsayılan sunucular Node.js/uv istiyordu; bunlar kurulu olmadığı için hiçbiri çalışmıyordu ve uygulama bunu söylemiyordu (v5.3.8'de görünür hale getirildi).

**Yapacağım:**
- `uv` ve taşınabilir bir Node'u uygulamayla birlikte dağıtmak.
- Resmi MCP özelliklerinin tamamı: OAuth, kaynaklar ve hazır istemler, `tools/list_changed` bildirimleri.
- Sunucu başına izin.
- Boşta kalan sunucuyu kapatma.
- MCP kayıt defterinden arama ve kurma.

## 7. Kurulum ve dağıtım

**Yapacağım:**
- Üç platform için bulutta derleme (v5.3.7'de eklendi).
- Python'u sistemden değil, uygulamayla birlikte taşımak (python-build-standalone + uv).
- İmzalı kurulum paketleri (Windows MSIX, macOS DMG, Linux AppImage/Flatpak) ve otomatik güncelleme.

**Neden:** Windows'ta "önce Flutter ve Visual Studio kur" adımı son kullanıcı için kabul edilemez.

## 8. Arayüz

**Şimdi:** `ide_shell.dart` 3.300, `agent_panel.dart` 1.360 satır.

**Yapacağım:**
- Özellik modüllerine bölmek.
- Tasarım belirteçleri (renk, boşluk, yazı).
- ARB ile çok dil desteği.
- Erişilebilirlik ve ekran görüntüsü (golden) testleri.

Bir **"Tanılama"** sayfası da eklerdim: donanım, model planı, ses servisleri, MCP ve skill durumu tek ekranda. Bu oturumlarda bulduğum sorunların çoğu böyle bir ekranda ilk gün görünürdü.

## Nasıl: adım adım yol haritası

| Aşama | İş | Neden önce |
|---|---|---|
| 1 | `lib/agent` + servisleri Flutter'dan bağımsız bir `feride_core` paketine taşı; `bin/feride_core.dart` JSON-RPC servisi | Hata yalıtımı ve testlenebilirlik en büyük kazanç |
| 2 | Model yöneticisi ve ses denetimini çekirdeğe al; arayüz yalnızca durumu göstersin | Çökmeler arayüzü etkilemesin |
| 3 | Sesi tek sürece indir (sherpa-onnx), yankı engelleme ekle, Ahenk'i ONNX'e çevir | Gecikme, sesle söz kesme, Python'suz ses |
| 4 | Korumalı alan, imzalı paketler, otomatik güncelleme | Güvenlik ve dağıtım |
| 5 | Arayüzü modüllere böl, Tanılama sayfası | Bakım kolaylığı |

Her aşamanın sonunda uygulama çalışır durumda kalır; mevcut testler (bugün 80+) her adımı korur.
