#!/usr/bin/env bash
# ==============================================================================
#  FerIDE Beta v5.3.8 — macOS (Apple Silicon Metal & Intel) Otonom Kurulum
#  Finder üzerinden çift tıklanarak veya Terminal'den çalıştırılabilir.
# ==============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR" || exit 1
export FERIDE_ROOT="$APP_DIR"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

FERIDE_HOME="$HOME/.feride"
mkdir -p "$FERIDE_HOME"/{models,models/mmproj,aegis,skills,todos,Chats,logs,bin/llama-cpp,tmp}

echo "================================================================"
echo "  FerIDE Beta v5.3.8 — macOS Otonom Kurulum Sihirbazı           "
echo "  Konum: $APP_DIR"
echo "================================================================"

# 1. Gatekeeper karantina bayraklarını ve izinleri onar
xattr -cr "$APP_DIR" 2>/dev/null || true
chmod +x "$APP_DIR/kurulum_macos.command" "$APP_DIR/baslat_macos.command" "$APP_DIR/kurulum.sh" "$APP_DIR/run.sh" 2>/dev/null || true
find "$APP_DIR/scripts" -maxdepth 2 -type f \( -name "*.sh" -o -name "*.py" \) -exec chmod +x {} + 2>/dev/null || true
[ -d "$APP_DIR/models/whisper" ] && chmod -R u+rwX,go+rX "$APP_DIR/models/whisper" 2>/dev/null || true
for p in "[s]tt_server.py" "[p]iper_tts_server.py" "[v]oice_engine_daemon.py"; do
  pkill -f "$p" 2>/dev/null || true
done

# 2. Homebrew üzerinden sistem bağımlılıklarını kur (varsa)
echo "[1/5] macOS sistem araçları (Python, FFmpeg, Aria2, Tesseract, Poppler) kontrol ediliyor..."
if command -v brew >/dev/null 2>&1; then
  for pkg in python aria2 ffmpeg poppler tesseract tesseract-lang libredwg; do
    brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg" 2>/dev/null || true
  done
else
  echo "  [!] Homebrew bulunamadı; sistem Python3 ve yerleşik araçlarla devam ediliyor (brew.sh önerilir)."
fi

# 3. Verileri ve dahili mmproj / yetenekleri senkronize et
echo "[2/5] ~/.feride çalışma dizini, Aegis hafızası ve mmproj hazırlanıyor..."
if [ -d "$APP_DIR/models/mmproj" ]; then
  for mm in "$APP_DIR/models/mmproj"/*.gguf; do
    [ -f "$mm" ] || continue
    tmm="$FERIDE_HOME/models/mmproj/$(basename "$mm")"
    [ -e "$tmm" ] || ln -sf "$mm" "$tmm" 2>/dev/null || cp -f "$mm" "$tmm" 2>/dev/null || true
  done
fi
[ -f "$APP_DIR/aegis_data/memory.db" ] && [ ! -f "$FERIDE_HOME/aegis/memory.db" ] && cp -f "$APP_DIR/aegis_data/memory.db" "$FERIDE_HOME/aegis/memory.db"
[ -d "$APP_DIR/skills_data" ] && cp -rn "$APP_DIR/skills_data/"* "$FERIDE_HOME/skills/" 2>/dev/null || true
[ -f "$APP_DIR/mcp_config.json" ] && [ ! -f "$FERIDE_HOME/mcp_config.json" ] && cp -f "$APP_DIR/mcp_config.json" "$FERIDE_HOME/mcp_config.json"

# 4. Python sanal ortamı (~/.feride/venv)
echo "[3/5] Python sanal ortamı ve çevrimdışı Whisper STT / Ofis paketleri kuruluyor..."
VENV_DIR="$FERIDE_HOME/venv"
if [ ! -x "$VENV_DIR/bin/python3" ]; then
  python3 -m venv "$VENV_DIR"
fi
if [ -x "$VENV_DIR/bin/pip" ]; then
  "$VENV_DIR/bin/pip" install --quiet --upgrade pip wheel 2>/dev/null || true
  "$VENV_DIR/bin/pip" install --quiet -r "$APP_DIR/requirements.txt" || true
  # Feride kadın sesi (Ahenk Cep, yerel)
  "$VENV_DIR/bin/python3" "$APP_DIR/scripts/setup_voice.py" || echo "[!] Kadın ses kurulamadı; erkek ses kullanılacak."
fi

# 5. macOS Apple Metal llama-server Otonom Kurulumu
echo "[4/5] macOS Apple Metal llama-server motoru kontrol ediliyor..."
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
  MAC_TAG="macos-arm64"
else
  MAC_TAG="macos-x64"
fi

if [ ! -x "$FERIDE_HOME/bin/llama-cpp/llama-server" ]; then
  RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/releases/latest 2>/dev/null || true)"
  ASSET_URL="$(printf '%s' "$RELEASE_JSON" | grep -oE "https://[^\"]+${MAC_TAG}\\.(tar\\.gz|zip)" | head -n1 || true)"
  if [ -n "$ASSET_URL" ]; then
    TMP_ARC="$FERIDE_HOME/tmp/llama_mac.archive"
    if curl -fL "$ASSET_URL" -o "$TMP_ARC"; then
      mkdir -p "$FERIDE_HOME/tmp/llama_mac_ext"
      case "$ASSET_URL" in
        *.zip) unzip -oq "$TMP_ARC" -d "$FERIDE_HOME/tmp/llama_mac_ext" ;;
        *) tar -xzf "$TMP_ARC" -C "$FERIDE_HOME/tmp/llama_mac_ext" ;;
      esac
      FOUND_SRV="$(find "$FERIDE_HOME/tmp/llama_mac_ext" -type f -name "llama-server" | head -n1)"
      if [ -n "$FOUND_SRV" ]; then
        cp -a "$(dirname "$FOUND_SRV")/"* "$FERIDE_HOME/bin/llama-cpp/"
        chmod +x "$FERIDE_HOME/bin/llama-cpp/"llama-* 2>/dev/null || true
        xattr -cr "$FERIDE_HOME/bin/llama-cpp" 2>/dev/null || true
        echo "  [✓] macOS ($MAC_TAG) Metal GPU llama-server başarıyla kuruldu."
      fi
      rm -rf "$TMP_ARC" "$FERIDE_HOME/tmp/llama_mac_ext"
    fi
  fi
fi

# 6. macOS Uygulama Paketi Kontrolü
echo "[5/5] FerIDE macOS uygulaması kontrol ediliyor..."
MAC_APP="$APP_DIR/build/macos/Build/Products/Release/feride_v5_2.app"
if [ ! -d "$MAC_APP" ] && command -v flutter >/dev/null 2>&1; then
  flutter pub get && flutter build macos --release
fi

echo ""
echo "================================================================"
echo "  🎉 FerIDE Beta v5.3.8 macOS Kurulumu Tamamlandı!              "
echo "  Başlatmak için 'baslat_macos.command' dosyasına çift tıklayın."
echo "================================================================"
