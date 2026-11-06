# FerIDE Beta v5.3.7

**FerIDE**, yerel GGUF yapay zeka modellerini (`llama.cpp` Vulkan / Apple Metal / ROCm / CUDA / CPU) tam otonom ajan mimarisi (**Aegis Hafıza + MCP + Yetenekler + Sesli Asistan + Evrensel Dosya & AutoCAD Stüdyosu**) ile birleştiren çapraz platform (**Linux, Windows, macOS**) yerel yapay zeka geliştirme ve çalışma ortamıdır.

## ✨ v5.3.7 Öne Çıkan Özellikler

- **Çapraz Platform Otonom Kurulum (`kurulum.sh` / `kurulum_windows.bat` / `kurulum_macos.command`):** Sıfırdan kurulmuş Linux, Windows ve macOS sistemlerde bağımlılıkları, Python sanal ortamını, izinleri ve `llama.cpp` motorunu otonom olarak hazırlar.
- **Kusursuz Sesli Konuşma (STT & TTS):**
  - Paket içinde **gömülü çevrimdışı Whisper STT** modeli (`models/whisper/base`) ve **gömülü Türkçe Piper TTS** modeli (`models/piper`) hazır gelir.
  - Python 3.14 / PyAV 14+ uyumlu doğrudan `16kHz float32` ses çözümleyici ile hem sohbet mikrofonunda hem de **Canlı Oturum (VAD)** modunda konuşmaları hatasız yazıya çevirir.
- **Geniş Ekran Ayarlar & 2 Sütunlu Model Merkezi:**
  - Genişletilmiş Ayarlar penceresinde sol sütunda HuggingFace GGUF arama sonuçlarını (hızlı filtreler ve tam boy kaydırma çubuğu ile), sağ sütunda ise yerel modellerinizi aynı anda görüntüleyin.
  - `aria2c` (16x) + yerleşik **Saf Dart Resumable HTTP** çift motorlu indirici ile tek/çok parçalı GGUF modelleri ve Vision `mmproj` adaptörlerini indirip otomatik başlatır.
- **Ayarlar İçinden Otonom `llama.cpp` Kurulumu/Güncellemesi:** **Ayarlar > Genel** sekmesinden Linux, Windows ve macOS için resmi GPU/CPU `llama-server` sürümlerini tek tıkla kurup güncelleyebilir.
- **Evrensel Dosya, Medya, Ofis ve AutoCAD Stüdyosu:**
  - **Ofis:** `.docx`, `.doc`, `.odt`, `.xlsx`, `.xls`, `.ods`, `.csv`, `.pptx`, `.ppt`, `.odp` okuma ve oluşturma/düzenleme.
  - **PDF & Görsel:** `.pdf`, `.png`, `.jpg`, `.webp`, `.svg` okuma, OCR, Vision (`mmproj`) analizi ve düzenleme.
  - **Ses & Müzik:** `.mp3`, `.wav`, `.flac`, `.ogg`, `.m4a`, `.aac`, `.opus` analiz, Whisper deşifre ve dönüştürme.
  - **AutoCAD:** Gömülü **LibreDWG** + `ezdxf` ile `.dwg` ve `.dxf` projelerini anlama, görselleştirme ve düzenleme/üretme.

## ⚡ Hızlı Başlangıç

- **Linux:** `bash kurulum.sh` -> ardından `./baslat.sh`
- **Windows:** `kurulum_windows.bat` -> ardından `baslat_windows.bat`
- **macOS:** `kurulum_macos.command` -> ardından `baslat_macos.command`

Ayrıntılı bilgi için [`KURULUM.md`](./KURULUM.md) dosyasına göz atabilirsiniz.
