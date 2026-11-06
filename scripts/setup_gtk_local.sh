#!/bin/bash
# ==============================================================================
# FerIDE — Sudo'suz Yerel GTK3/GStreamer Kurulumu
# ----------------------------------------------------------------------------
# Hazır derlenmiş FerIDE binary'si libgtk-3 ve GStreamer kütüphanelerine ihtiyaç
# duyar. Sistemde sudo yoksa veya dağıtım farklıysa bu script kütüphaneleri
# $HOME/opt/gtkdev altına indirir. run.sh bu yolu LD_LIBRARY_PATH'e ekler.
#
# Kullanım: bash scripts/setup_gtk_local.sh
# ==============================================================================
set -e
ROOT="$HOME/opt/gtkdev"
LIB="$ROOT/usr/lib/x86_64-linux-gnu"
PKG="$ROOT/usr/lib/x86_64-linux-gnu/pkgconfig"
SHARE="$ROOT/usr/share/pkgconfig"
mkdir -p "$LIB" "$PKG" "$SHARE"

echo "=== FerIDE yerel GTK3 kurulumu: $ROOT ==="

# 1) uv ile hızlı wheel tabanlı kurulum (sudo gerektirmez)
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
  echo "[1/4] uv kuruluyor..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# 2) GTK3 + GStreamer kütüphanelerini .so olarak çeken paketler
echo "[2/4] GTK3/GStreamer kütüphaneleri indiriliyor..."
uvx --from pyinstaller pyinstaller --version >/dev/null 2>&1 || true
uv pip install --python "$(command -v python3)" --target "$ROOT/pylibs" \
    pygobject gstreamer 2>/dev/null || true

# 3) .so dosyalarını kopyala (wheel'lerden)
echo "[3/4] .so dosyaları kopyalanıyor..."
find "$ROOT/pylibs" -name "*.so*" -exec cp -an {} "$LIB/" \; 2>/dev/null || true
find "$ROOT/pylibs" -name "*.pc" -exec cp -an {} "$PKG/" \; 2>/dev/null || true

# 4) Doğrulama
echo "[4/4] Doğrulama..."
if ls "$LIB"/libgtk-3.so* >/dev/null 2>&1; then
  echo "✓ libgtk-3 bulundu: $(ls "$LIB"/libgtk-3.so* | head -1)"
else
  echo "⚠️  libgtk-3 bulunamadı. Alternatif: distro paketinden kopyala:"
  echo "   Ubuntu/Debian: sudo apt install -y libgtk-3-0t64 libgstreamer1.0-0t64 libgstreamer-plugins-base1.0-0"
  echo "   Ardından: sudo cp /usr/lib/x86_64-linux-gnu/libgtk-3.so* $LIB/  (veya sudo ile çalıştır)"
fi

# run.sh bu yolu otomatik kullanır — ek işlem gerekmez.
echo "=== Tamam. Şimdi: FerIDE dizininde ./run.sh ==="
