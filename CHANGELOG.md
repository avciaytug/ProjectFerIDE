# Sürüm notları

## v5.4.25 beta — Daha sağlam düzenleme, düzenleme sonrası otomatik hata denetimi

**Ajanın dosya düzenlemesi**

- `edit_file` artık metni birebir bulamadığında pes etmiyor. Yerel modellerin en sık yaptığı kopyalama hatalarını
  tolere ediyor:
  - eksik ya da fazla girinti
  - sekme ve boşluk karışıklığı
  - satır başı/sonu boşlukları ve satır içi fazla boşluklar
  - blok içinde atlanan ya da eklenen boş satırlar
  - `\n` gibi harfiyen yazılmış kaçış dizileri

  Gevşek eşleşme yalnızca dosyada tek bir yere uyuyorsa uygulanıyor. Yeni metnin girintisi dosyanınkine uyduruluyor
  (gerekirse boşluklar sekmeye çevriliyor). Model, ne yapıldığını ve değişikliğin farkını aynı çıktıda görüyor.
- Metin hiçbir yerde bulunamazsa hata mesajında dosyadaki en benzer bölüm satır numaralarıyla gösteriliyor. Model dosyayı
  baştan okumadan doğru metni kopyalayabiliyor.
- Aynı dosyada birden çok değişiklik tek çağrıda yapılabiliyor (`edits` listesi). Hepsi birlikte uygulanıyor ya da hiçbiri;
  her model adımı yerel modelde pahalı olduğu için bu, işleri belirgin şekilde hızlandırıyor.
- Düzeltme: girintisi eksik kopyalanmış tek satırlık bir metin girintinin ortasında birebir eşleşince, eklenen sonraki
  satırlar yanlış girintiyle yazılıyordu. Ayrıca CRLF (Windows) satır sonlu dosyalara LF satır sonu karışabiliyordu.
- Var olan bir dosyanın üzerine, ajan onu o oturumda okumadan (ya da okuduktan sonra dosya değişmişken) `write_file` ile
  yazılamıyor. Ajan önce okumaya yönlendiriliyor; yerel modeller kullanıcının dosyasını okumadan baştan yazabiliyordu.

**Düzenleme sonrası otomatik denetim**

- Ajan bir dosyayı yazınca ya da düzenleyince dosyanın diline göre hızlı bir hata denetimi çalışıyor. Bulunan hatalar aynı
  araç çıktısında, satır numarasıyla ajana bildiriliyor; ajan bunları başka işe geçmeden düzeltiyor.
- Her modda yalnızca dosyayı çalıştırmayan denetimler kullanılıyor:
  - JSON ve TOML (FerIDE'nin içinde)
  - Python (derleme, `__pycache__` oluşturmadan)
  - JavaScript (`node --check`)
  - kabuk betikleri (`bash -n`)
  - Go (`gofmt -e`)
  - Rust (`rustfmt`)
- "Hiçbir şey sorma" modunda ayrıca Rust için `cargo check` ve TypeScript için projedeki `tsc` çalışıyor. Yalnızca
  düzenlenen dosyanın hataları gösteriliyor, diğer dosyalardaki hatalar sayı olarak bildiriliyor. Bu iki denetim projenin
  kodunu da çalıştırabildiği (derleme betikleri, `node_modules`) için diğer modlarda kendiliğinden çalışmıyor.
- Yanlış alarm vermemesi için JSX içeren `.js` dosyaları ve yorum içerebilen JSON dosyaları (`tsconfig`, `.vscode`)
  denetlenmiyor. Windows Mağazası'nın sahte `python.exe` kısayolu ve WSL başlatıcısı kullanılmıyor.
- Ayarlar → Ajan ve güvenlik → **Düzenleme sonrası denetim** ile kapatılabiliyor.

**Sürüm numarası**

- Sürüm numarası sadeleşti: `5.4.0-beta.24`'ten sonra **v5.4.25 beta** geliyor. Beta sayısı artık sürümün son hanesi
  (sonraki: v5.4.26 beta). Pencere başlığı, üst çubuk, karşılama sayfası, Ayarlar ve GitHub'daki sürüm adı bu biçimi
  kullanıyor.
- Uygulama içi güncelleme ve kurulum betikleri yeni numarayı eski beta'lardan yeni sayıyor; güncelleme her zamanki gibi
  gelir.

## beta v5.4 (5.4.0-beta.24) — Ajan, FerIDE'nin model sunucusunu artık kapatamıyor

- **"Model sunucusuna ulaşılamadı" hatasının nedeni:** ajan başka bir program için (ör. opencode) ayrı llama-server'lar
  başlatıp yönetirken FerIDE'nin kendi model sunucusunu da kapatıyordu. Bunu ya adla toplu kapatarak
  (`Get-Process -Name llama-server | Stop-Process`) ya da yanlış PID'i hedefleyerek yapıyordu. Sunucu kapanınca
  konuşma kopuyordu.
- Ajanın komutları artık çalıştırılmadan önce denetleniyor. FerIDE'nin model sunucusunu ya da FerIDE'nin kendisini
  kapatacak komutlar çalıştırılmıyor; ajan bunun yerine, kendi başlattığı bir sunucuyu yalnızca o sunucunun PID'iyle
  kapatabileceğini söyleyen bir açıklama alıyor. Engellenenler:
  - llama-server süreçlerini adıyla toplu kapatan komutlar (`Stop-Process -Name`, `taskkill /IM`, `pkill`,
    `Get-Process … | Stop-Process` ve benzerleri)
  - model sunucusunun PID'ini ya da portunu hedefleyen komutlar
  - bunları içeren `.ps1`, `.bat`, `.sh` ve `.py` betikleri
- Model sunucusu görev ortasında yine de kapanırsa (çökme, başka bir programın kapatması), FerIDE onu yeniden
  başlatıyor ve görev kaldığı yerden sürüyor. Bir görevde en fazla 3 kez yeniden başlatılıyor; "Devam et" demeye
  gerek kalmıyor. Yeniden açılan sunucunun bağlam boyu farklıysa ajan yenisine göre çalışıyor.
- Sunucu kapandıktan sonra "Devam et" denince eski hata bazen model yüklenmeden hemen yeniden gösteriliyordu
  (bu yüzden mesajı iki kez göndermek gerekebiliyordu). Artık model yeniden yüklenene kadar bekleniyor.

## beta v5.4 (5.4.0-beta.23) — Ayarlar'da tekrar eden seçimler kaldırıldı

- Ayarlar → Ajan ve güvenlik'ten **İzin modu** bölümü ve **Düşünme modu** satırı kaldırıldı. İkisi de zaten mesaj
  kutusunun altında: izin modu seçicisi ve "Düşünme" anahtarı.
- Her modun açıklaması ve her modda geçerli korumalar artık izin modu seçicisinin üzerine gelince görünüyor.

## beta v5.4 (5.4.0-beta.22) — Görsel adaptör (mmproj) bir kez iniyor

- **Aynı modelin farklı sürümleri artık tek görsel adaptörü paylaşıyor.** Önceden Q4_K, Q8_0 gibi her kuantizasyon
  için aynı adaptör yeniden iniyordu (Qwen3.8-27B'de 931 MB × 2). Adaptör artık model ailesinin adıyla kaydediliyor
  (ör. `Huihui-Qwen3.8-27B-abliterated__mmproj-model-bf16.gguf`). Bu bilgisayarda zaten varsa, eski adlandırmayla bir
  sürüm için inmiş olsa bile, yeniden indirilmiyor.
- Model Merkezi'ndeki kutu adaptörün boyutunu ve ne işe yaradığını yazıyor: model ekran görüntülerini ve resimleri
  anlayabilsin, indirmek isteğe bağlı. Birden çok çeşit varsa en uygunu seçiliyor: F16, sonra BF16, Q8; iki kat büyük
  F32 en son.
- Kutunun işaretini kaldırırsanız bu seçim ayarlara kaydediliyor ve sonraki indirmelerde, FerIDE yeniden açılsa da,
  kapalı geliyor.

## beta v5.4 (5.4.0-beta.21) — Kaldırıcı her sürücüde programı siliyor

- Windows'ta kaldırıcı, kurulum programlarının yaptığı gibi kendini Geçici klasöre kopyalayıp oradan çalışıyor.
  Böylece program klasöründeki `feride.exe` doğrudan siliniyor. beta.20'de çalışan dosya Geçici klasöre *taşınıyordu*;
  FerIDE başka bir sürücüye (ör. `D:\Programlar`) kuruluysa bu yapılamıyor ve dosya yerinde kalıyordu. Geçici
  klasördeki kopya bir sonraki kurulumda temizleniyor.
- Kaldırırken önce veriler (istenirse), en son program dosyası siliniyor.

## beta v5.4 (5.4.0-beta.20) — PowerShell'siz Windows bütünleşmesi, "nul" dosyaları

- **FerIDE artık kendi işleri için PowerShell çalıştırmıyor.** Microsoft Defender, beta.19'u
  "Trojan:Win32/Bearfoos.B!ml" sanıp karantinaya aldı. Bu, makine öğrenmesine dayalı yanlış bir alarmdı; programın
  içinde kötü amaçlı yazılımlarla aynı biçimde yazılmış PowerShell kalıpları vardı. Hepsi doğrudan Windows API'siyle
  yeniden yazıldı:
  - Başlat menüsü ve masaüstü kısayolları Windows'un kısayol arayüzüyle (IShellLink) oluşturuluyor. Önceden gizli
    pencerede `powershell -ExecutionPolicy Bypass -EncodedCommand` ve WScript kullanılıyordu.
  - Kullanıcı PATH'i ve "Yüklü uygulamalar" kaydı Kayıt Defteri API'siyle yazılıyor. PATH'teki diğer girdilere, boş
    olanlar dahil, dokunulmuyor.
  - Kaldırırken çalışan program dosyası Windows'un Geçici klasörüne taşınıyor. Önceden FerIDE kapandıktan sonra onu
    silmek için gizli bir PowerShell başlatılıyordu.
  - Kurulum'daki yönetici adımı (Visual C++ çalışma zamanı, uzun yollar): FerIDE kendisini yönetici olarak açıp işi
    doğrudan yapıyor. Önceden gizli pencerede yönetici PowerShell betiği çalışıyordu; UAC penceresinde artık
    "Windows PowerShell" yerine FerIDE görünüyor.
  - ROCm için ekran kartı adları kayıt defterinden okunuyor (önceden `powershell Get-CimInstance`).
  - Bağlantı ve dosya açma Windows'un `ShellExecuteEx` işleviyle yapılıyor. Kullanılan kütüphane her seferinde gizli
    bir PowerShell başlatıyordu.
  - Ajanın yedek PowerShell kabuğu `-ExecutionPolicy Bypass` yerine `RemoteSigned` kullanıyor.
- **Gezginde "Sil" artık `nul`, `con`, `aux` gibi adlı dosyaları da siliyor.** Windows bu adları aygıt olarak
  yorumladığından dosya açılamıyor, taşınamıyor, silinemiyordu. Dosya işlemleri artık `\\?\` önekli ham yol
  kullanıyor; okuma ve yeniden adlandırma da çalışıyor. Bu adlarla yeni dosya oluşturmak açık bir hatayla engelleniyor.
- **Ajan bu dosyaları artık oluşturmuyor.** Git Bash'te `komut 2>nul` çıktıyı atmaz, `nul` adlı bir dosyaya yazar.
  Kullanıcının bilgisayarındaki dosyada `wmic: command not found` yazıyordu. Ajanın bash komutlarındaki `>nul`,
  `2>nul`, `<nul` yönlendirmeleri artık çalıştırılmadan önce `/dev/null`'a çevriliyor.

## beta v5.4 (5.4.0-beta.19) — Ctrl+T, isteğe bağlı güncelleme, Windows engelleri

- **Terminal kısayolu artık Ctrl+T** (Türkçe klavyede ters tırnak AltGr istiyordu). Terminal odaktayken de paneli
  açıp kapatır; eski Ctrl+` da çalışmaya devam eder.
- **"Yeni sürümleri otomatik indir ve kur" kapalıyken hiçbir şey indirilmez.** Önceden "Şimdi denetle" kutuya bakmadan
  indirip kuruyordu. Artık yalnızca bakar; yeni sürüm varsa durum çubuğunda "Yeni sürüm …", Ayarlar'da
  **İndir ve kur** düğmesi çıkar.
- **Windows Akıllı Uygulama Denetimi yeni sürümü engellerse** ham hata ("os error 4551") yerine anlaşılır bir açıklama,
  **Yeniden dene** ve **Windows Güvenlik'i aç** düğmeleri gösterilir. Çalışan sürüm korunur. Otomatik güncelleme
  aynı sürümü 3 gün boyunca yeniden indirmez; önceden her denemede ~9 MB inip yeni bir Windows bildirimi açılıyordu.
- Windows "Yüklü uygulamalar" listesindeki FerIDE sürümü güncellemeden sonra artık yenileniyor. Kayıt PowerShell
  betiğiyle yazılıyordu ve masaüstü uygulamasından çağrılınca sessizce başarısız oluyordu (listede beta.15 kalmıştı).
  Artık doğrudan Windows API'siyle yazılıyor.

## beta v5.4 (5.4.0-beta.18) — Küçük ekran kartları ve Windows Akıllı Uygulama Denetimi

- **6 GB ekran kartında 4 GB'lık model artık tamamen GPU'da çalışıyor.** Örnek: Gemma 4 12B UD-IQ2_M, 32K bağlam,
  GPU'da ~4,6 GiB. Önceden "7,1 GiB gerekiyor, GPU'da 3,2 GiB kullanılabilir" deniyordu. Nedenleri:
  - NVIDIA'lı dizüstünde Vulkan listesindeki Intel UHD yüzünden bütün sistem "paylaşımlı bellekli" sayılıyor ve
    ayrık karttan %35 (2,1 GiB) masaüstü payı düşülüyordu. Artık karar yalnızca modelin çalışacağı karta göre veriliyor;
    birden çok GPU varsa ayrık kart seçiliyor.
  - Ayrık kartta güvenlik payı 1 GiB yerine 512 MiB – 2 GiB (kartın ~%6'sı).
  - Hesap tamponu sabit 1,5 GiB yerine modelin yapısından hesaplanıyor (kelime dağarcığı, FFN genişliği, toplu
    işlem, bağlam); yinelemeli katmanların durumu da sayılıyor. Tahmin llama.cpp'nin gerçek ölçümlerinin biraz üstünde.
  - Toplu işlem boyutu (`-ub`) belleğe göre seçiliyor: bol bellekte 2048, küçük kartta 1024/512/256.
  - Görsel adaptör (mmproj) GPU'ya sığmıyorsa işlemcide çalışıyor (`--no-mmproj-offload`).
- **GPU modunda seçilen bağlam sığmıyorsa** model engellenmiyor: sığan en büyük bağlamla tamamen GPU'da başlatılıp
  uyarı gösteriliyor. Hiç sığmıyorsa mesaj neyin ne kadar yer tuttuğunu söylüyor (model, bağlam önbelleği, çalışma alanı).
- **Windows "Bu uygulamanın bir kısmı engellendi" bildirimleri kesildi.** llama.cpp her açılışta ~14 işlemci çeşidini
  (`ggml-cpu-*.dll`) ve RPC arka ucunu yüklemeyi deniyordu. Akıllı Uygulama Denetimi bunlardan itibarı olmayanları
  (ör. bu işlemcinin zaten kullanamadığı `ggml-cpu-skylakex.dll`) her seferinde engelleyip bildirim gösteriyordu.
  FerIDE artık kullanılan çeşidi öğrenip gerisini `kullanilmayan` alt klasörüne taşıyor; silmiyor.
- Akıllı Uygulama Denetimi uyarısı yalnızca Windows bir bileşeni gerçekten engellediğinde gösteriliyor. Ayarın açık
  olması tek başına her açılışta uyarı açtırmıyor.

## beta v5.4 (5.4.0-beta.17) — Yazı boyutu ayarı geri geldi

- Ayarlar → Genel'e **Yazı boyutu (düzenleyici)** geri eklendi (12–18 px). Kayıtlı değeriniz seçili gelir.
- Yeni boyut açık dosyalara da hemen uygulanır; önceden yalnızca sonradan açılan dosyalarda geçerli oluyordu.

## beta v5.4 (5.4.0-beta.16) — Ayarlar'dan "Satır kaydırma" kaldırıldı

- Ayarlar → Genel'den **Satır kaydırma** da kaldırıldı; kod düzenleyici uzun satırları kaydırmadan (yatay kaydırma
  çubuğuyla) göstermeye devam eder.

## beta v5.4 (5.4.0-beta.15) — Sadeleşen Ayarlar

- Ayarlar → Genel'den **Tema**, **Yazı boyutu** ve **Sekme genişliği** kaldırıldı. Tema üst çubuktaki güneş/ay
  düğmesiyle değiştirilir; düzenleyici kayıtlı yazı boyutu ve sekme genişliğini kullanmaya devam eder.
- **FerIDE hakkında** bölümüne yapımcı eklendi: Aytuğ AVCI.
- Otomatik güncellemeyle gelen ilk sürüm: beta.14 kullanıcılarına kendiliğinden ulaşır.

## beta v5.4 (5.4.0-beta.14) — Otomatik güncelleme

- **FerIDE artık kendini güncelliyor:** kurulu FerIDE açıkken GitHub'daki yeni sürümleri denetler (açılıştan
  1 dakika sonra, sonra 6 saatte bir). Yeni sürüm varsa arka planda indirir, SHA-256 ile doğrular, yeni programın bu
  bilgisayarda çalıştığını sınar ve kurar; çalışmanız kesilmez. Çalışan FerIDE eski dosyadan devam eder; yeni sürüm
  yeniden başlatınca devreye girer. Durum çubuğunda **Güncelleme hazır** belirir: tıklayınca sürüm notları gösterilir
  ve **Yeniden başlat** ile FerIDE yeni sürümle açılır (yüklü model yeniden yüklenir). Yeniden başlatmazsanız yeni
  sürüm bir sonraki açılışta gelir.
- Ayarlar → Genel → **Güncellemeler**: otomatik güncellemeyi aç/kapat, **Şimdi denetle**, durum ve sürüm notları.
- Komut satırı: `feride update` (indirip kurar), `feride update --check` (yalnızca denetler).
- Yalnızca kurulu kopyalar kendini günceller; geliştirme ve taşınabilir kopyalara dokunulmaz. Yeni sürüm çalışmazsa
  (bozuk paket, Windows Akıllı Uygulama Denetimi…) kurulmaz, mevcut sürüm korunur. Sürümler GitHub'ın listeleme
  sırasına göre değil sürüm numarasına göre karşılaştırılır; eski sürüme dönülmez.
- Kaldırıcı ve kurulum betikleri güncellemeden kalan eski program dosyasını (`feride.old.exe`) da temizler.

## beta v5.4 (5.4.0-beta.13) — Model yüklüyken plan önizlemesi

- Bir model yüklüyken Model Merkezi'ndeki **Plan** düğmesi, yüklü modelin kullandığı RAM'i ve Windows sanal bellek
  taahhüdünü de dolu sayıyordu; aslında sığan bir model için yanlış "taahhüt sınırı aşılacak" ya da "RAM yetmiyor"
  diyebiliyordu. Yeni model başlatılırken önce yüklü olan kapatıldığı için önizleme artık onun belleğini boş sayıyor.
  Başlatma zaten doğru hesaplıyordu.

## beta v5.4 (5.4.0-beta.12) — GPU'ya ayrılmış bellek (VRAM) doğru hesaplanıyor

- **AMD Adrenalin'de "Değişken Grafik Belleği" büyütülünce model GPU'da çalışmıyordu:** FerIDE Radeon 8060S gibi
  tümleşik GPU'ları "belleği RAM ile paylaşan" GPU sayıyor ve modelin boş RAM'e de sığmasını istiyordu. GPU'ya
  96 GB ayrılıp Windows'a 32 GB RAM kalınca 36 GB'lık model "sığmıyor" deniyordu. FerIDE artık GPU'ya ayrılmış belleği
  okuyor (Windows: sürücü kaydı, Linux: amdgpu VRAM): model bu kısma sığdığı sürece RAM'den yer kaplamıyor, yalnızca
  aşan kısım RAM'den sayılıyor. Radeon 8060S (96 GB ayrılmış / 32 GB RAM) üzerinde 27B Q8 modeli tamamen GPU'da,
  128K bağlamla çalışıyor: 4,8 token/sn (Q4: 12,7 token/sn).
- GPU modunda gerçek neden RAM yetersizliğiyse artık bu söyleniyor (önceki mesaj yanıltıcı biçimde GPU rakamlarını
  gösteriyordu).
- CPU offload (MoE) seçiliyken uzmanlara RAM yetmiyor ama model tamamen GPU'ya sığıyorsa model engellenmiyor, GPU'da
  başlatılıyor.
- Windows GPU'ya yüklenen belleği sanal bellek (taahhüt) sınırından da düşüyor; sınır aşılacaksa FerIDE uyarıyor
  (sayfa dosyası kapalı ya da sabitse model yüklenemez).
- Donanım bilgisinde ayrılmış GPU belleği gösteriliyor ("96 GiB ayrılmış, kalanı paylaşımlı").

## beta v5.4 (5.4.0-beta.11) — Çalışan ROCm seçeneği, "Kur / güncelle" düzeltmesi

- **"Kur / güncelle" gerçekten kuruyor:** Model Merkezi'ndeki düğme llama.cpp zaten kuruluysa hiçbir şey yapmıyordu;
  başka bir derleme (ROCm, CUDA…) seçilse de eskisi kalıyordu. Artık seçilen derleme her seferinde kurulur ve sonuç
  (kuruldu / neden kurulamadı) ekranda bildirilir.
- **Windows'ta ROCm:** llama.cpp'nin kendi Windows ROCm paketi hipBLAS/rocBLAS kitaplıklarını içermediği için GPU'yu
  görmüyordu. FerIDE artık AMD Lemonade projesinin GPU ailesine özel (ör. Radeon 8060S → gfx1151), kitaplıkları içeren
  ve donanımda doğrulanmış derlemesini kurar; paket SHA-256 ile doğrulanır.
- **Kurulumdan sonra GPU denetimi:** elle seçilen GPU derlemesi (ROCm, CUDA, Vulkan) ekran kartını görmüyorsa kurulmaz,
  önceki derleme korunur ve nedeni söylenir — model sessizce işlemcide çalışmaz.
- Ölçüm (Radeon 8060S, Qwen 27B Q4): ROCm istem okumada ~%30 hızlı, yanıt üretmede Vulkan %10–25 hızlı. Otomatik
  seçim Vulkan olarak kalıyor.

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
