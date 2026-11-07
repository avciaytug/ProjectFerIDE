# FerIDE'yi Windows veya macOS'a taşıma (v5.3.8)

Bu klasör üç işletim sistemi için aynı kaynak kodunu içerir. Klasördeki **hazır çalıştırılabilir dosya ise yalnızca Linux içindir.** Windows `.exe`'si Windows'ta, macOS `.app`'i macOS'ta derlenir; Flutter masaüstü uygulamaları başka bir işletim sisteminde derlenemez. Kurulum betikleri bunu sizin yerinize yapar.

## Windows 10 / 11

1. Zip'i kısa ve boşluksuz bir yola açın, örneğin `C:\FerIDE`.
2. **`kurulum_windows.bat`** dosyasına çift tıklayın. Sırasıyla şunları yapar:
   - Python 3.12, FFmpeg ve aria2'yi winget ile kurar.
   - `%USERPROFILE%\.feride\venv` ortamını ve Python kütüphanelerini kurar. Whisper STT ve Piper erkek sesi dahildir.
   - **Feride kadın sesini** kurar (`scripts\setup_voice.py`). Model dosyaları klasörde hazır olduğu için yalnızca PyTorch (CPU) indirilir.
   - llama.cpp'nin Windows Vulkan sürümünü (`llama-server.exe`) kurar.
   - Flutter yoksa onayınızı alıp **Git + Flutter SDK + Visual Studio 2022 C++ Build Tools** kurar (bir kez, yaklaşık 6-8 GB).
   - `feride_v5_2.exe`'yi derler (ilk derleme 5-10 dk) ve masaüstüne kısayol koyar.
3. **Dil modelleri:** büyük GGUF modelleriniz bu klasörde değildir. Linux'taki `~/.feride/models/*.gguf` dosyalarını (USB disk ile) Windows'ta `%USERPROFILE%\.feride\models\` klasörüne kopyalayın. Ya da uygulamada **Ayarlar > Model Merkezi**'nden indirin.
4. **`baslat_windows.bat`** ile ya da masaüstü kısayoluyla başlatın.

Notlar:
- İlk açılışta Windows mikrofon izni isteyebilir: **Ayarlar > Gizlilik > Mikrofon > Masaüstü uygulamaları** açık olmalı.
- Ses çalma Windows'un yerleşik SoundPlayer'ıyla yapılır; ek bir şey gerekmez.
- Komutlar PowerShell'de çalışır. Ajana "terminal komutu" yerine işi tarif etmeniz yeterli.

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
| Windows/macOS'ta gerçek çalıştırma | ⚠️ Bu makinede yapılamadı; ilk testiniz bu olacak. Sorun çıkarsa `%USERPROFILE%\.feride\logs\` içeriğini paylaşın |
