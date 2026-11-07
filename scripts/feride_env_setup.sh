#!/usr/bin/env bash
# ==============================================================================
#  FerIDE Beta v5.3.8 — Kullanıcı Alanı (Sudo Gerektirmeyen) Python Ortam Kurucu
#  ~/.feride/venv sanal ortamını oluşturur ve requirements.txt içindeki tüm
#  Ofis, PDF, Resim, Ses, AutoCAD (ezdxf) ve STT/TTS kütüphanelerini kurar.
# ==============================================================================
set -e

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FERIDE_HOME="${HOME:-$(eval echo ~)}/.feride"
VENV_DIR="$FERIDE_HOME/venv"
LOG_FILE="$FERIDE_HOME/logs/python_env_setup.log"

mkdir -p "$FERIDE_HOME/logs"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== FerIDE v5.3.8 Python Ortam Kurulumu: $(date) ==="

if [ ! -x "$VENV_DIR/bin/python3" ]; then
  echo "[1/3] ~/.feride/venv oluşturuluyor..."
  python3 -m venv "$VENV_DIR"
fi

echo "[2/3] pip güncelleniyor ve requirements.txt kuruluyor..."
"$VENV_DIR/bin/pip" install --upgrade pip wheel
if [ -f "$APP_DIR/requirements.txt" ]; then
  "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"
fi
"$VENV_DIR/bin/python3" "$APP_DIR/scripts/setup_voice.py" || echo "[!] Kadın ses kurulamadı; erkek ses kullanılacak."

echo "[3/3] Modül doğrulaması..."
"$VENV_DIR/bin/python3" - <<'EOF'
import docx, openpyxl, pptx, odf, fitz, reportlab, PIL, pytesseract, mutagen, pydub, ezdxf, matplotlib, faster_whisper, piper
print("✓ Tüm Evrensel Dosya, AutoCAD ve Ses modülleri doğrulandı.")
EOF

chmod +x "$APP_DIR/scripts/feride_env_setup.sh" 2>/dev/null || true
echo "=== Kurulum başarıyla tamamlandı ==="
