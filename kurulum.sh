#!/usr/bin/env bash
# ==============================================================================
#  FerIDE Beta v5.3.5 — Tam Otonom Kurulum, Bağımlılık ve Onarım Sihirbazı
#  Sıfırdan formatlanmış Ubuntu / Kubuntu / Debian / Fedora / Arch sistemlerde
#  tek tıkla veya terminalden tüm bağımlılıkları kurar, izinleri ve sembolik
#  bağları onarır, gömülü llama.cpp + mmproj + LibreDWG + Python ortamını
#  doğrular ve masaüstü kısayolunu oluşturur.
#
#  Kullanım:
#    bash kurulum.sh               # Etkileşimli tam kurulum (çift tık destekli)
#    bash kurulum.sh --autonomous  # FerIDE Ayarlar içinden otonom/sessiz kurulum
#    bash kurulum.sh --launch      # Kurulum biter bitmez FerIDE'yi başlatır
# ==============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR" || exit 1

AUTONOMOUS=0
AUTO_LAUNCH=0
IN_TERMINAL=0

for arg in "$@"; do
  case "$arg" in
    --autonomous|--non-interactive|-y) AUTONOMOUS=1 ;;
    --launch) AUTO_LAUNCH=1 ;;
    --in-terminal) IN_TERMINAL=1 ;;
  esac
done

# Dosya yöneticisinden (Dolphin / Nautilus vb.) çift tıklandığında otomatik uçbirim aç
if [ "$AUTONOMOUS" -eq 0 ] && [ "$IN_TERMINAL" -eq 0 ] && [ ! -t 0 ]; then
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    if command -v konsole >/dev/null 2>&1; then
      exec konsole --hold -e bash "$APP_DIR/kurulum.sh" --in-terminal "$@"
    elif command -v gnome-terminal >/dev/null 2>&1; then
      exec gnome-terminal -- bash -c "\"$APP_DIR/kurulum.sh\" --in-terminal $*; echo; read -rp 'Kapatmak için Enter tuşuna basın...' _"
    elif command -v xfce4-terminal >/dev/null 2>&1; then
      exec xfce4-terminal --hold -e "bash \"$APP_DIR/kurulum.sh\" --in-terminal $*"
    elif command -v x-terminal-emulator >/dev/null 2>&1; then
      exec x-terminal-emulator -e bash "$APP_DIR/kurulum.sh" --in-terminal "$@"
    else
      # Uçbirim emülatörü yoksa otonom modda (Polkit ile) devam et
      AUTONOMOUS=1
    fi
  fi
fi

mkdir -p "$HOME/.feride/logs"
LOG_FILE="$HOME/.feride/logs/kurulum.log"
exec > >(tee -a "$LOG_FILE") 2>&1

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${BLUE}[FerIDE]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}   FerIDE Beta v5.3.5 — Otonom Sistem Kurulum Sihirbazı         ${NC}"
echo -e "${BLUE}   Konum: ${APP_DIR}${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# ADIM 1: exFAT / NTFS / ZIP İzin ve .so Sembolik Bağ Onarımı (Taşınabilirlik)
# ------------------------------------------------------------------------------
info "[1/7] Çalıştırma izinleri ve yerel kütüphane bağları onarılıyor..."

chmod +x "$APP_DIR/kurulum.sh" "$APP_DIR/run.sh" "$APP_DIR/baslat.sh" "$APP_DIR/kurulum_macos.command" "$APP_DIR/baslat_macos.command" 2>/dev/null || true
find "$APP_DIR/scripts" -maxdepth 2 -type f \( -name "*.sh" -o -name "*.py" \) -exec chmod +x {} + 2>/dev/null || true
[ -d "$APP_DIR/models/whisper" ] && chmod -R u+rwX,go+rX "$APP_DIR/models/whisper" 2>/dev/null || true
# Eski bir oturumdan kalmış ses sunucuları varsa temizle ki güncel STT/TTS betikleri devreye girsin
for p in "[s]tt_server.py" "[p]iper_tts_server.py" "[v]oice_engine_daemon.py"; do
  pkill -f "$p" 2>/dev/null || true
done

BUNDLE_DIR="$APP_DIR/build/linux/x64/release/bundle"
BUNDLE_BIN="$BUNDLE_DIR/feride_v5_2"
if [ -f "$BUNDLE_BIN" ]; then
  chmod +x "$BUNDLE_BIN" 2>/dev/null || true
fi
if [ -d "$BUNDLE_DIR/lib" ]; then
  find "$BUNDLE_DIR/lib" -maxdepth 1 -type f -name "*.so*" -exec chmod +x {} + 2>/dev/null || true
fi

if [ -d "$APP_DIR/bin/cad" ]; then
  find "$APP_DIR/bin/cad" -maxdepth 1 -type f -exec chmod +x {} + 2>/dev/null || true
fi

repair_so_links() {
  local libdir="$1"
  [ -d "$libdir" ] || return 0
  find "$libdir" -maxdepth 1 -type f \( -name "llama-*" -o -name "*.so*" \) -exec chmod +x {} + 2>/dev/null || true
  (
    cd "$libdir" || exit 0
    for full in lib*.so.*.*.*; do
      [ -f "$full" ] || continue
      # örn: libllama.so.0.0.12034 -> soname: libllama.so.0, base: libllama.so
      base="${full%%.so.*}.so"
      rest="${full#*.so.}"
      major="${rest%%.*}"
      soname="${base}.${major}"
      if [ ! -e "$soname" ] || [ ! -s "$soname" ]; then
        rm -f "$soname" 2>/dev/null || true
        ln -sf "$full" "$soname" 2>/dev/null || cp -f "$full" "$soname" 2>/dev/null || true
      fi
      if [ ! -e "$base" ] || [ ! -s "$base" ]; then
        rm -f "$base" 2>/dev/null || true
        ln -sf "$soname" "$base" 2>/dev/null || cp -f "$full" "$base" 2>/dev/null || true
      fi
    done
  )
}

repair_so_links "$APP_DIR/bin/llama-cpp"
repair_so_links "$HOME/.feride/bin/llama-cpp"
ok "İzinler ve paylaşımlı kütüphane (.so) sembolik bağları doğrulandı."

# ------------------------------------------------------------------------------
# ADIM 2: Sistem Paketleri (apt / dnf / pacman)
# ------------------------------------------------------------------------------
info "[2/7] Sistem bağımlılıkları kontrol ediliyor..."

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    bash -c "$*"
    return $?
  fi
  if sudo -n true 2>/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive bash -c "$*"
    return $?
  fi
  if [ "$AUTONOMOUS" -eq 1 ]; then
    if command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
      pkexec env DEBIAN_FRONTEND=noninteractive bash -c "$*"
      return $?
    fi
    return 1
  else
    sudo DEBIAN_FRONTEND=noninteractive bash -c "$*"
    return $?
  fi
}

NEED_SYS_INSTALL=0
for cmd in aria2c ffmpeg pdftoppm tesseract python3 curl unzip parecord; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    NEED_SYS_INSTALL=1
    break
  fi
done
if ! python3 -m venv --help >/dev/null 2>&1; then
  NEED_SYS_INSTALL=1
fi
if [ -f "$BUNDLE_BIN" ] && ldd "$BUNDLE_BIN" 2>&1 | grep -q "not found"; then
  NEED_SYS_INSTALL=1
fi
if [ -f "$APP_DIR/bin/llama-cpp/llama-server" ] && LD_LIBRARY_PATH="$APP_DIR/bin/llama-cpp:${LD_LIBRARY_PATH:-}" ldd "$APP_DIR/bin/llama-cpp/llama-server" 2>&1 | grep -q "not found"; then
  NEED_SYS_INSTALL=1
fi

if [ "$NEED_SYS_INSTALL" -eq 1 ]; then
  info "Eksik sistem paketleri tespit edildi, paket yöneticisi ile kuruluyor..."
  if command -v apt-get >/dev/null 2>&1; then
    GTK_PKG="libgtk-3-0"
    if apt-cache show libgtk-3-0t64 >/dev/null 2>&1; then
      GTK_PKG="libgtk-3-0t64"
    fi
    SSL3_PKG=""
    if apt-cache show libssl3t64 >/dev/null 2>&1; then
      SSL3_PKG="libssl3t64"
    elif apt-cache show libssl3 >/dev/null 2>&1; then
      SSL3_PKG="libssl3"
    fi
    APT_CMD="apt-get update -qq && apt-get install -y --no-install-recommends \
      $GTK_PKG $SSL3_PKG libglib2.0-0 libgdk-pixbuf-2.0-0 libpango-1.0-0 libcairo2 libepoxy0 \
      libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 gstreamer1.0-plugins-good \
      pulseaudio-utils alsa-utils espeak-ng \
      libsqlite3-0 libvulkan1 mesa-vulkan-drivers vulkan-tools pciutils \
      libgomp1 libatomic1 aria2 ffmpeg poppler-utils ripgrep \
      tesseract-ocr tesseract-ocr-tur tesseract-ocr-eng \
      python3 python3-venv python3-pip curl git unzip zip xz-utils \
      wl-clipboard xclip xdg-utils"
    if run_as_root "$APT_CMD"; then
      ok "Sistem paketleri (apt) başarıyla kuruldu."
    else
      warn "Root yetkisi alınamadı; yerel (kullanıcı alanı) yedek kurulum uygulanacak."
    fi
  elif command -v dnf >/dev/null 2>&1; then
    DNF_CMD="dnf install -y gtk3 glib2 gstreamer1 gstreamer1-plugins-base pulseaudio-utils alsa-utils espeak-ng sqlite-libs \
      vulkan-loader vulkan-tools aria2 ffmpeg poppler-utils tesseract tesseract-langpack-tur \
      python3 python3-pip curl git unzip zip xz wl-clipboard xclip xdg-utils"
    run_as_root "$DNF_CMD" && ok "Sistem paketleri (dnf) kuruldu." || warn "dnf kurulumu atlandı."
  elif command -v pacman >/dev/null 2>&1; then
    PAC_CMD="pacman -Sy --noconfirm --needed gtk3 glib2 gstreamer gst-plugins-base libpulse alsa-utils espeak-ng sqlite \
      vulkan-icd-loader vulkan-tools aria2 ffmpeg poppler tesseract tesseract-data-tur tesseract-data-eng \
      python python-pip curl git unzip zip xz wl-clipboard xclip xdg-utils"
    run_as_root "$PAC_CMD" && ok "Sistem paketleri (pacman) kuruldu." || warn "pacman kurulumu atlandı."
  fi
else
  ok "Tüm temel sistem ve mikrofon/ses araçları (aria2c, ffmpeg, parecord, poppler, tesseract, GTK3, Python venv) zaten kurulu."
fi

# ------------------------------------------------------------------------------
# ADIM 3: Kalıcı Veri Klasörleri (~/.feride), Yetenekler, MCP ve Dahili mmproj
# ------------------------------------------------------------------------------
info "[3/7] Kullanıcı çalışma dizini (~/.feride), Aegis hafızası, yetenekler ve mmproj hazırlanıyor..."

FERIDE_HOME="$HOME/.feride"
mkdir -p "$FERIDE_HOME"/{models,models/mmproj,aegis,skills,todos,Chats,logs,bin,tmp}
mkdir -p "$APP_DIR/models/mmproj" "$APP_DIR/Chats"

# Dahili mmproj dosyalarını ~/.feride/models/mmproj içine de yansıt (yedekli erişim)
if [ -d "$APP_DIR/models/mmproj" ]; then
  for mm in "$APP_DIR/models/mmproj"/*.gguf; do
    [ -f "$mm" ] || continue
    target_mm="$FERIDE_HOME/models/mmproj/$(basename "$mm")"
    if [ ! -e "$target_mm" ]; then
      ln -sf "$mm" "$target_mm" 2>/dev/null || cp -f "$mm" "$target_mm" 2>/dev/null || true
    fi
  done
  ok "Dahili Vision mmproj hazır ($(ls -1 "$APP_DIR/models/mmproj"/*.gguf 2>/dev/null | wc -l) adet)."
fi

# Aegis DB (mevcut kullanıcı verisini ezmeden yükle)
if [ -d "$APP_DIR/aegis_data" ] && [ -f "$APP_DIR/aegis_data/memory.db" ]; then
  if [ ! -f "$FERIDE_HOME/aegis/memory.db" ]; then
    cp -f "$APP_DIR/aegis_data/memory.db" "$FERIDE_HOME/aegis/memory.db"
    ok "Başlangıç Aegis veritabanı aktarıldı."
  fi
fi

# Yetenekleri (Skills) birleştirerek güncelle (yeni yetenekleri ekler, kullanıcı yeteneklerini silmez)
if [ -d "$APP_DIR/skills_data" ]; then
  cp -rn "$APP_DIR/skills_data/"* "$FERIDE_HOME/skills/" 2>/dev/null || true
  # universal-file-and-cad-studio her zaman güncel kalsın
  if [ -d "$APP_DIR/skills_data/universal-file-and-cad-studio" ]; then
    mkdir -p "$FERIDE_HOME/skills/universal-file-and-cad-studio"
    cp -rf "$APP_DIR/skills_data/universal-file-and-cad-studio/"* "$FERIDE_HOME/skills/universal-file-and-cad-studio/" 2>/dev/null || true
  fi
  ok "Yetenek kütüphanesi senkronize edildi ($(find "$FERIDE_HOME/skills" -name "SKILL.md" 2>/dev/null | wc -l) yetenek)."
fi

# Todos & MCP Config
if [ -d "$APP_DIR/todos_data" ] && [ -z "$(ls -A "$FERIDE_HOME/todos" 2>/dev/null)" ]; then
  cp -rf "$APP_DIR/todos_data/"* "$FERIDE_HOME/todos/" 2>/dev/null || true
fi
if [ -f "$APP_DIR/mcp_config.json" ] && [ ! -f "$FERIDE_HOME/mcp_config.json" ]; then
  cp -f "$APP_DIR/mcp_config.json" "$FERIDE_HOME/mcp_config.json"
fi

# ------------------------------------------------------------------------------
# ADIM 4: llama.cpp Sunucusu (Gömülü Doğrulama + Otonom İndirme Yedeği)
# ------------------------------------------------------------------------------
info "[4/7] llama.cpp (llama-server) motoru doğrulanıyor..."

# Ubuntu/Kubuntu 26.10+ (OpenSSL 4) root'suz yedek: libssl.so.3 eksikse apt-get download ile yerel çıkar
if [ -f "$APP_DIR/bin/llama-cpp/llama-server" ] && \
   LD_LIBRARY_PATH="$APP_DIR/bin/llama-cpp:${LD_LIBRARY_PATH:-}" ldd "$APP_DIR/bin/llama-cpp/llama-server" 2>&1 | grep -q "libssl.so.3 => not found"; then
  if command -v apt-get >/dev/null 2>&1 && command -v dpkg-deb >/dev/null 2>&1; then
    info "OpenSSL 3 uyumluluk kütüphaneleri (libssl.so.3 / libcrypto.so.3) yerel olarak hazırlanıyor..."
    SSL_TMP="$FERIDE_HOME/tmp/ssl3_auto"
    rm -rf "$SSL_TMP" && mkdir -p "$SSL_TMP"
    (
      cd "$SSL_TMP" && (apt-get download libssl3t64 >/dev/null 2>&1 || apt-get download libssl3 >/dev/null 2>&1) && \
      dpkg-deb -x libssl3*.deb "$SSL_TMP/ext" && \
      find "$SSL_TMP/ext" -type f \( -name "libssl.so.3*" -o -name "libcrypto.so.3*" \) -exec cp -f {} "$APP_DIR/bin/llama-cpp/" \;
    ) || true
    rm -rf "$SSL_TMP"
  fi
fi

# Gömülü Vulkan GPU llama-server'ı kullanıcı dizinine senkronize et
if [ -d "$APP_DIR/bin/llama-cpp" ]; then
  mkdir -p "$FERIDE_HOME/bin/llama-cpp"
  if [ ! -f "$FERIDE_HOME/bin/llama-cpp/libggml-vulkan.so" ] && [ -f "$APP_DIR/bin/llama-cpp/libggml-vulkan.so" ]; then
    cp -a "$APP_DIR/bin/llama-cpp/"* "$FERIDE_HOME/bin/llama-cpp/"
    repair_so_links "$FERIDE_HOME/bin/llama-cpp"
  fi
fi

LLAMA_OK=0
if [ -x "$APP_DIR/bin/llama-cpp/llama-server" ]; then
  if LD_LIBRARY_PATH="$APP_DIR/bin/llama-cpp:${LD_LIBRARY_PATH:-}" "$APP_DIR/bin/llama-cpp/llama-server" --version >/dev/null 2>&1; then
    LLAMA_OK=1
    ok "Gömülü llama-server (Vulkan GPU + CPU) çalışmaya hazır."
  fi
fi
if [ "$LLAMA_OK" -eq 0 ] && [ -x "$FERIDE_HOME/bin/llama-cpp/llama-server" ]; then
  if LD_LIBRARY_PATH="$FERIDE_HOME/bin/llama-cpp:$APP_DIR/bin/llama-cpp:${LD_LIBRARY_PATH:-}" "$FERIDE_HOME/bin/llama-cpp/llama-server" --version >/dev/null 2>&1; then
    LLAMA_OK=1
    ok "Kullanıcı dizinindeki llama-server çalışmaya hazır."
  fi
fi

if [ "$LLAMA_OK" -eq 0 ]; then
  warn "Gömülü llama-server çalışmadı veya eksik; GitHub üzerinden otonom indiriliyor..."
  mkdir -p "$FERIDE_HOME/bin/llama-cpp"
  FLAVOR="vulkan"
  if ! command -v vulkaninfo >/dev/null 2>&1 && [ ! -e /dev/dri ]; then
    FLAVOR="cpu"
  fi
  RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=5 2>/dev/null || true)"
  if [ "$FLAVOR" = "vulkan" ]; then
    ASSET_URL="$(printf '%s' "$RELEASE_JSON" | grep -oE 'https://[^"]+ubuntu-vulkan-x64\.(tar\.gz|zip)' | head -n1 || true)"
  else
    ASSET_URL=""
  fi
  if [ -z "$ASSET_URL" ]; then
    ASSET_URL="$(printf '%s' "$RELEASE_JSON" | grep -oE 'https://[^"]+ubuntu-x64\.(tar\.gz|zip)' | grep -v vulkan | grep -v rocm | head -n1 || true)"
  fi
  if [ -n "$ASSET_URL" ]; then
    TMP_ARC="$FERIDE_HOME/tmp/llama_auto.archive"
    if curl -fL "$ASSET_URL" -o "$TMP_ARC"; then
      mkdir -p "$FERIDE_HOME/tmp/llama_extract"
      rm -rf "$FERIDE_HOME/tmp/llama_extract/"*
      case "$ASSET_URL" in
        *.zip) unzip -q -o "$TMP_ARC" -d "$FERIDE_HOME/tmp/llama_extract" ;;
        *) tar -xzf "$TMP_ARC" -C "$FERIDE_HOME/tmp/llama_extract" ;;
      esac
      FOUND_SRV="$(find "$FERIDE_HOME/tmp/llama_extract" -type f -name "llama-server" | head -n1)"
      if [ -n "$FOUND_SRV" ]; then
        SRV_DIR="$(dirname "$FOUND_SRV")"
        cp -a "$SRV_DIR/"* "$FERIDE_HOME/bin/llama-cpp/"
        for ssl_so in libssl.so.3 libcrypto.so.3; do
          [ -f "$APP_DIR/bin/llama-cpp/$ssl_so" ] && cp -f "$APP_DIR/bin/llama-cpp/$ssl_so" "$FERIDE_HOME/bin/llama-cpp/$ssl_so" 2>/dev/null || true
        done
        repair_so_links "$FERIDE_HOME/bin/llama-cpp"
        ok "llama.cpp GitHub üzerinden otonom olarak indirildi ve kuruldu."
      fi
      rm -rf "$TMP_ARC" "$FERIDE_HOME/tmp/llama_extract"
    fi
  else
    warn "İnternet bağlantısı yok veya GitHub erişilemedi. FerIDE içinden Ayarlar > Genel sekmesinden tek tıkla kurabilirsiniz."
  fi
fi

# ------------------------------------------------------------------------------
# ADIM 5: Python Sanal Ortamı (~/.feride/venv) — Ofis, PDF, Resim, Ses, AutoCAD
# ------------------------------------------------------------------------------
info "[5/7] Python Çoklu-Ortam & Ofis & AutoCAD sanal ortamı (~/.feride/venv) kuruluyor..."

VENV_DIR="$FERIDE_HOME/venv"
if [ ! -x "$VENV_DIR/bin/python3" ]; then
  python3 -m venv "$VENV_DIR" || warn "python3-venv oluşturulamadı; python3-venv paketini kontrol edin."
fi

if [ -x "$VENV_DIR/bin/pip" ] && [ -f "$APP_DIR/requirements.txt" ]; then
  "$VENV_DIR/bin/pip" install --quiet --upgrade pip wheel 2>/dev/null || true
  if "$VENV_DIR/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"; then
    ok "Python kütüphaneleri (Word, Excel, PowerPoint, ODF, PDF, OCR, Ses, AutoCAD DXF/DWG, STT/TTS) hazır."
  else
    warn "Bazı Python paketleri çevrimdışı ortam nedeniyle atlandı; internet olduğunda Ayarlar'dan onarabilirsiniz."
  fi
fi

# LibreDWG kontrolü
if [ -x "$APP_DIR/bin/cad/dwg2dxf" ] && [ -x "$APP_DIR/bin/cad/dxf2dwg" ]; then
  ok "Gömülü AutoCAD DWG <-> DXF motoru (LibreDWG) hazır."
fi

# ------------------------------------------------------------------------------
# ADIM 6: Yerel GTK/Derleme Kontrolü
# ------------------------------------------------------------------------------
info "[6/7] FerIDE çalıştırılabilir ikili dosyası (Release Binary) kontrol ediliyor..."

if [ -x "$BUNDLE_BIN" ] && ! ldd "$BUNDLE_BIN" 2>&1 | grep -q "not found"; then
  ok "Derlenmiş Release uygulaması bu sistemle %100 uyumlu."
else
  warn "Eksik sistem kütüphanesi veya derleme algılandı, yerel onarım deneniyor..."
  if [ -f "$APP_DIR/setup_gtk_local.sh" ]; then
    bash "$APP_DIR/setup_gtk_local.sh" || true
  fi
  export PATH="$HOME/opt/flutter/bin:$HOME/flutter/bin:$PATH"
  if [ ! -x "$BUNDLE_BIN" ] && command -v flutter >/dev/null 2>&1; then
    flutter pub get && flutter build linux --release
  fi
fi

# ------------------------------------------------------------------------------
# ADIM 7: Masaüstü ve Uygulama Menüsü Kısayolları
# ------------------------------------------------------------------------------
info "[7/7] Masaüstü ve Başlat Menüsü kısayolları oluşturuluyor..."

ICON_PATH="$APP_DIR/assets/app_icon.png"
APP_MENU_DIR="$HOME/.local/share/applications"
mkdir -p "$APP_MENU_DIR"

DESKTOP_CONTENT="[Desktop Entry]
Version=1.0
Type=Application
Name=FerIDE Beta v5.3.5
GenericName=Otonom Yerel Yapay Zeka IDE
Comment=Otonom Yerel Yapay Zeka Asistanı ve Evrensel Dosya Stüdyosu
Exec=\"$APP_DIR/run.sh\"
Path=$APP_DIR
Icon=$ICON_PATH
Terminal=false
Categories=Development;IDE;Utility;
StartupNotify=true
StartupWMClass=feride_v5_2
"

printf '%s' "$DESKTOP_CONTENT" > "$APP_MENU_DIR/feride.desktop"
chmod +x "$APP_MENU_DIR/feride.desktop"

PORTABLE_DESKTOP_CONTENT="[Desktop Entry]
Version=1.0
Type=Application
Name=FerIDE Beta v5.3.5
GenericName=Otonom Yerel Yapay Zeka IDE
Comment=Otonom Yerel Yapay Zeka Asistanı ve Evrensel Dosya Stüdyosu
Exec=sh -c 'DIR=\"\$(cd \"\$(dirname \"\$1\")\" && pwd)\" && exec \"\$DIR/run.sh\"' -- %k
Icon=utilities-terminal
Terminal=false
Categories=Development;IDE;Utility;
StartupNotify=true
StartupWMClass=feride_v5_2
"
printf '%s' "$PORTABLE_DESKTOP_CONTENT" > "$APP_DIR/FerIDE.desktop"
chmod +x "$APP_DIR/FerIDE.desktop"

DESKTOP_DIR=""
if command -v xdg-user-dir >/dev/null 2>&1; then
  DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
fi
if [ -z "$DESKTOP_DIR" ] || [ ! -d "$DESKTOP_DIR" ]; then
  if [ -d "$HOME/Masaüstü" ]; then
    DESKTOP_DIR="$HOME/Masaüstü"
  elif [ -d "$HOME/Desktop" ]; then
    DESKTOP_DIR="$HOME/Desktop"
  fi
fi

if [ -n "$DESKTOP_DIR" ] && [ -d "$DESKTOP_DIR" ]; then
  printf '%s' "$DESKTOP_CONTENT" > "$DESKTOP_DIR/FerIDE.desktop"
  chmod +x "$DESKTOP_DIR/FerIDE.desktop"
  command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_DIR/FerIDE.desktop" metadata::trusted true 2>/dev/null || true
  ok "Masaüstü kısayolu oluşturuldu: $DESKTOP_DIR/FerIDE.desktop"
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_MENU_DIR" 2>/dev/null || true

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}   🎉 FerIDE Beta v5.3.5 Kurulumu Başarıyla Tamamlandı!          ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "  • Uygulamayı masaüstündeki ${BLUE}FerIDE Beta v5.3.5${NC} simgesinden veya"
echo -e "    klasör içindeki ${BLUE}baslat.sh${NC} / ${BLUE}run.sh${NC} dosyasına tıklayarak açabilirsiniz."
echo -e "  • Model Merkezi'nden dilediğiniz GGUF modelini tek tıkla indirebilirsiniz."
echo -e "  • Ayarlar > Genel sekmesinden llama.cpp ve sistem bileşenlerini her zaman"
echo -e "    otonom olarak güncelleyebilir veya onarabilirsiniz."
echo ""

if [ "$AUTO_LAUNCH" -eq 1 ]; then
  nohup "$APP_DIR/run.sh" >/dev/null 2>&1 &
fi

exit 0
