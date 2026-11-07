# FerIDE'yi Windows veya macOS'a taşıma (v5.3.8)

Bu klasör üç işletim sistemi için aynı kaynak kodunu içerir. Klasördeki **hazır çalıştırılabilir dosya ise yalnızca Linux içindir.** Windows `.exe`'si Windows'ta, macOS `.app`'i macOS'ta derlenir; Flutter masaüstü uygulamaları başka bir işletim sisteminde derlenemez. Kurulum betikleri bunu sizin yerinize yapar.

## Windows 10 / 11

Tek adım: zip'i açın, klasördeki **`baslat_windows.bat`** dosyasına çift tıklayın.

- Uygulama henüz derlenmemişse kurulum kendiliğinden başlar ve bitince FerIDE açılır. Sonraki açılışlarda doğrudan açılır.
- Windows "Bilgisayarınız korundu" uyarısı gösterirse **Ek bilgi > Yine de çalıştır**'a tıklayın.
- Kurulum yalnızca ilk sefer sırasıyla şunları yapar:
  - Python 3.12, FFmpeg ve aria2'yi winget ile kurar. `%USERPROFILE%\.feride\venv` ortamını hazırlar: Whisper STT, Piper ve Feride kadın sesi.
  - llama.cpp'nin Windows Vulkan sürümünü (`llama-server.exe`) indirir.
  - Eksikse onayınızla **Git, Flutter SDK ve Visual Studio 2022 C++ Build Tools**'u kurar (~6-8 GB).
  - Flutter'ın eklentiler için istediği **Geliştirici Modu**'nu açar. Bunun için bir kez Windows yönetici onayı istenir.
  - `feride_v5_2.exe`'yi `%LOCALAPPDATA%\FerIDE\src` içinde derler (5-15 dk). Kısa, boşluksuz yol, uzun yol sorunlarını önler. Sonucu bu klasörün `build\windows\x64\runner\Release` altına kopyalar.
  - Masaüstüne **FerIDE** kısayolu koyar.
- **Dil modelleri:** büyük GGUF dosyaları zip'te yoktur. Linux'taki `~/.feride/models/*.gguf` dosyalarını `%USERPROFILE%\.feride\models\` içine kopyalayın ya da **Ayarlar > Model Merkezi**'nden indirin.
- Sorun çıkarsa günlük şurada: `%USERPROFILE%\.feride\logs\kurulum_windows.log`.

Notlar:
- Mikrofon için **Ayarlar > Gizlilik > Mikrofon > Masaüstü uygulamaları** açık olmalı.
- Ses çalma Windows'un yerleşik SoundPlayer'ıyla yapılır; komutlar PowerShell'de çalışır.

## macOS (Apple Silicon / Intel)

1. Xcode'u ve Homebrew'u kurun: `xcode-select --install`.
2. **`kurulum_macos.command`** dosyasına çift tıklayın. Python ortamını, kadın sesi, Metal destekli llama-server'ı kurar ve Flutter varsa `.app`'i derler.
3. **`baslat_macos.command`** ile başlatın. İlk açılışta mikrofon izni verin.

## Büyük modeller ve GPU/CPU seçimi (her platformda)

**Ayarlar > Genel > Model Çalıştırma** bölümünden dört mod seçilebilir:

| Mod | Ne yapar |
|---|---|
| Otomatik (önerilen) | FerIDE belleği ölçer. Model sığıyorsa tamamını GPU'ya, sığmıyorsa sığan kısmını GPU'ya ve kalanını RAM'e koyar; bağlamı da buna göre seçer. |
| GPU offload | Modelin tamamı GPU'da çalışır. Sığmıyorsa model başlatılmaz ve nedeni gösterilir. |
| CPU offload | MoE modellerinde uzman ağırlıkları RAM'de, kalanı GPU'da. GPU belleği azken en kararlısı. |
| Yalnızca CPU | Ekran kartı kullanılmaz. |

- **Windows/NVIDIA:** GPU belleği `CUDA0` aygıtından, **macOS:** `MTL0` (paylaşımlı bellek) aygıtından otomatik ölçülür.
- **Linux AMD APU (Strix Halo vb.):** GPU varsayılan olarak RAM'in yalnızca yarısını kullanabilir. Ayarlar'daki komutla (`sudo bash scripts/gpu_bellek_ayari.sh`) bu sınır yükseltilebilir. Windows'ta bu sınır sürücü ve BIOS ayarlarıyla belirlenir; ayrıca bir işlem gerekmez.

## Bulutta otomatik derleme (isteğe bağlı)

Proje GitHub'a yüklenirse `.github/workflows/build.yml` üç platformun paketlerini otomatik derler. Bir `v*` etiketi gönderildiğinde ya da Actions sekmesinden elle başlatıldığında çalışır. Böylece Windows'ta Visual Studio kurmadan hazır `.exe` alınabilir.

## Bu sürümde doğrulananlar / doğrulanmayanlar

| Konu | Durum |
|---|---|
| Linux (Kubuntu 26.10) native derleme, testler, ses hattı | ✅ Bu makinede test edildi |
| Windows betik kodlaması (`kurulum.ps1` UTF-8 BOM + CRLF, `.bat` CRLF) | ✅ Düzeltildi. PowerShell 5.1, BOM'suz UTF-8 dosyalardaki "—" karakteri yüzünden betiği hiç çalıştıramıyordu |
| Windows/macOS kod yolları (Python, PowerShell, ses çalma, ekran görüntüsü, yol çözümleme) | ✅ Kod incelemesiyle kontrol edildi |
| Windows ikili adı | ✅ Düzeltildi: derleme `feride_v4.exe` üretiyor, betikler `feride_v5_2.exe` arıyordu (macOS'ta da aynı uyuşmazlık vardı) |
| Windows/macOS'ta gerçek çalıştırma | ⚠️ Bu makinede yapılamadı; ilk testiniz bu olacak. Sorun çıkarsa `%USERPROFILE%\.feride\logs\` içeriğini paylaşın |
