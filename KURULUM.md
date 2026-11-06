# FerIDE Beta v5.3.4 — Kurulum ve Format Sonrası Hızlı Başlangıç Kılavuzu (Linux • Windows • macOS)

**FerIDE Beta v5.3.4**, sıfırdan kurulmuş bir işletim sisteminde (**Linux, Windows 10/11 ve macOS**) tüm bağımlılıklarını, sesli konuşma motorunu (`Whisper STT` + `Piper/Sistem TTS`), çoklu dosya ayrıştırıcılarını ve `llama.cpp` çıkarım motorunu otonom olarak kurup çalıştıracak şekilde paketlenmiştir.

---

## 🐧 1. Linux'ta Sıfırdan Kurulum (Kubuntu, Ubuntu, Debian, Fedora, Arch)

1. **`FerIDE beta 5.3.4.zip`** dosyasını Masaüstüne (veya dilediğiniz bir klasöre) çıkartın.
2. Klasörün içindeki **`kurulum.sh`** dosyasına çift tıklayın *(veya uçbirimde `bash kurulum.sh` çalıştırın)*.
3. Kurulum sihirbazı **bulunduğu klasörü başka bir yere kopyalamadan** yerinde kurulum yapar:
   - Çalıştırma izinlerini (`+x`) ve paylaşımlı `.so` sembolik bağlarını onarır.
   - Eksik sistem ve mikrofon paketlerini (`aria2`, `ffmpeg`, `pulseaudio-utils`, `alsa-utils`, `espeak-ng`, `poppler-utils`, `tesseract-ocr`, Türkçe OCR, Vulkan sürücü araçları, GTK3, `python3-venv`) otomatik kurar.
   - `~/.feride/venv` ortamını kurup Ofis, PDF, Görsel, Ses/Müzik, AutoCAD (`DWG`/`DXF`) ve Sesli Konuşma (`faster-whisper` + `piper-tts`) paketlerini hazırlar.
   - Gömülü **Çevrimdışı Whisper STT** modelini, Türkçe **Piper TTS** ses modelini, **`llama-server` (Vulkan GPU + CPU)** motorunu, dahili **`mmproj`** görsel adaptörünü ve **LibreDWG** araçlarını doğrular.
   - Masaüstüne ve Başlat Menüsüne **FerIDE Beta v5.3.4** kısayolunu ekler.
4. Başlatmak için Masaüstündeki kısayola veya klasördeki **`baslat.sh`** / **`run.sh`** dosyasına çift tıklayın.

---

## 🪟 2. Windows 10 / 11'de Sıfırdan Kurulum

1. **`FerIDE beta 5.3.4.zip`** arşivini çıkartın.
2. **`kurulum_windows.bat`** dosyasına çift tıklayın:
   - `WinGet` üzerinden eksikse Python 3.12, FFmpeg ve Aria2 araçlarını otomatik kurar.
   - `%USERPROFILE%\.feride\venv` ortamını ve ses/ofis/CAD kütüphanelerini hazırlar.
   - Resmi GitHub sürümünden Windows Vulkan **`llama-server.exe`** motorunu `%USERPROFILE%\.feride\bin\llama-cpp\` altına otonom indirir.
   - Masaüstüne **FerIDE Beta v5.3.4** kısayolunu oluşturur.
3. Başlatmak için **`baslat_windows.bat`** dosyasına veya Masaüstü kısayoluna çift tıklayın. *(Not: Paket Linux üzerinde derlendiği için Windows'ta ilk çalıştırmada Flutter Windows SDK varsa `feride_v5_2.exe` otomatik derlenir.)*

---

## 🍎 3. macOS'ta Sıfırdan Kurulum (Apple Silicon M1/M2/M3/M4 & Intel)

1. **`FerIDE beta 5.3.4.zip`** arşivini çıkartın.
2. **`kurulum_macos.command`** dosyasına çift tıklayın *(veya Terminal'de `bash kurulum_macos.command` çalıştırın)*:
   - Gatekeeper karantina izinlerini otomatik onarır.
   - Homebrew üzerinden eksik araçları (`python`, `ffmpeg`, `aria2`, `poppler`, `tesseract`, `libredwg`) tamamlar.
   - `~/.feride/venv` ortamını kurar ve resmi **Apple Metal GPU** destekli `llama-server` ikilisini `~/.feride/bin/llama-cpp/` altına otonom indirir.
3. Başlatmak için **`baslat_macos.command`** dosyasına çift tıklayın.

---

## 🎙️ Sesli Konuşma (STT) ve Canlı Sesli Oturum

- Sohbet kutusundaki **Mikrofon (🎤)** simgesine tıklayıp konuştuğunuzda ve tekrar tıkladığınızda konuşmanız **gömülü çevrimdışı Whisper STT** motoruyla anında Türkçe metne çevrilip mesaj kutusuna yazılır.
- **Canlı Oturum (Live Session)** modunda gerçek zamanlı ses algılama (VAD) ile eller serbest konuşabilirsiniz.
- STT modeli (`models/whisper/base`) ve Türkçe seslendirme modeli (`models/piper`) paket içinde hazır geldiği için ilk kullanımda internetten model indirmeyi beklemez; arka planda internet varsa daha yüksek doğruluklu `small` modeline kesintisiz yükseltilir.

---

## 🧠 Geniş Ekran Ayarlar & 2 Sütunlu Model Merkezi

1. Sağ üstteki **Ayarlar (⚙️) > Model Merkezi** sekmesini açın.
2. Genişletilmiş 2 sütunlu pencerede:
   - **Sol Sütun:** HuggingFace üzerinde GGUF model araması yapın (veya tek tıkla hızlı filtre etiketlerini kullanın), kaydırılabilir listede 30'a kadar sonucu rahatça inceleyip istediğiniz kuantizasyonu (`Q4_K_M`, `Q6_K`, `Q8_0` vb.) indirin.
   - **Sağ Sütun:** Bilgisayarınızdaki indirilmiş modelleri görün, tek tıkla (`▶`) çalıştırın veya yönetin.
3. İndirme tamamlandığı anda model (ve varsa Vision `mmproj` eklentisi) **otomatik olarak FerIDE'ye entegre edilir ve GPU hızlandırmasıyla başlatılır**.

---

## 🩺 Sistem Sağlık Kontrolü (Linux)

```bash
bash scripts/feride_doctor.sh
```
Tüm çalışma ve ses sunucusu günlükleri `~/.feride/logs/` klasöründe tutulur.
