#!/usr/bin/env bash
# ==============================================================================
#  FerIDE Beta v5.3.8 — Tam Sistem Sağlık ve Bağımlılık Denetçisi (feride_doctor)
# ==============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FERIDE_HOME="$HOME/.feride"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0

check_ok()   { echo -e "  ${GREEN}[✓]${NC} $*"; PASS=$((PASS+1)); }
check_warn() { echo -e "  ${YELLOW}[!]${NC} $*"; WARN=$((WARN+1)); }
check_fail() { echo -e "  ${RED}[✗]${NC} $*"; FAIL=$((FAIL+1)); }

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}   FerIDE Beta v5.3.8 — Sistem Doktoru (feride_doctor.sh)       ${NC}"
echo -e "${BLUE}================================================================${NC}"

echo -e "\n${BLUE}1. Çekirdek Uygulama ve Çıkarım Motoru:${NC}"
BUNDLE_BIN="$APP_DIR/build/linux/x64/release/bundle/feride_v5_2"
if [ -x "$BUNDLE_BIN" ] && ! ldd "$BUNDLE_BIN" 2>&1 | grep -q "not found"; then
  check_ok "FerIDE Linux Release İkilisi hazır ($BUNDLE_BIN)"
else
  check_fail "FerIDE Release ikilisi eksik veya kütüphane hatası var!"
fi

if [ -x "$APP_DIR/bin/llama-cpp/llama-server" ] && LD_LIBRARY_PATH="$APP_DIR/bin/llama-cpp" "$APP_DIR/bin/llama-cpp/llama-server" --version >/dev/null 2>&1; then
  VER="$(LD_LIBRARY_PATH="$APP_DIR/bin/llama-cpp" "$APP_DIR/bin/llama-cpp/llama-server" --version 2>&1 | head -n2 | tr '\n' ' ')"
  check_ok "Gömülü llama-server çalışıyor: $VER"
elif [ -x "$FERIDE_HOME/bin/llama-cpp/llama-server" ]; then
  check_ok "Kullanıcı dizinindeki llama-server çalışıyor ($FERIDE_HOME/bin/llama-cpp/llama-server)"
else
  check_fail "llama-server bulunamadı!"
fi

MMPROJ_COUNT=$(find "$APP_DIR/models/mmproj" "$FERIDE_HOME/models/mmproj" -maxdepth 1 -name "*.gguf" 2>/dev/null | wc -l)
if [ "$MMPROJ_COUNT" -gt 0 ]; then
  check_ok "Dahili Vision mmproj hazır ($MMPROJ_COUNT eşleşme bulundu)"
else
  check_warn "Henüz mmproj dosyası bulunamadı"
fi

if [ -f "$APP_DIR/models/whisper/base/model.bin" ]; then
  check_ok "Gömülü Çevrimdışı Whisper STT modeli hazır ($APP_DIR/models/whisper/base)"
else
  check_warn "Gömülü Whisper STT modeli bulunamadı (ilk açılışta indirilecek)"
fi

if [ -f "$APP_DIR/models/piper/tr_TR-fahrettin-medium.onnx" ]; then
  check_ok "Gömülü Türkçe Piper TTS ses modeli hazır"
else
  check_warn "Gömülü Türkçe Piper TTS modeli bulunamadı"
fi

echo -e "\n${BLUE}2. İndirme, Mikrofon, Çoklu-Ortam ve OCR Sistem Araçları:${NC}"
for tool in aria2c ffmpeg parecord pdftoppm tesseract python3; do
  if command -v "$tool" >/dev/null 2>&1; then
    check_ok "$tool kurulu ($(command -v "$tool"))"
  else
    check_warn "$tool bulunamadı (Saf Dart/Python yedeği devreye girer; tam hız için kurulum.sh çalıştırın)"
  fi
done

if [ -x "$APP_DIR/bin/cad/dwg2dxf" ] && [ -x "$APP_DIR/bin/cad/dxf2dwg" ]; then
  check_ok "AutoCAD DWG <-> DXF motoru (LibreDWG 0.14) gömülü ve hazır"
else
  check_warn "LibreDWG ikilileri bulunamadı"
fi

echo -e "\n${BLUE}3. Python Evrensel Dosya ve Ses Ortamı (~/.feride/venv):${NC}"
PY_BIN="$FERIDE_HOME/venv/bin/python3"
if [ -x "$PY_BIN" ]; then
  check_ok "Python sanal ortamı mevcut ($PY_BIN)"
  for mod in docx openpyxl pptx odf fitz reportlab PIL pytesseract mutagen pydub ezdxf matplotlib faster_whisper piper; do
    if "$PY_BIN" -c "import $mod" >/dev/null 2>&1; then
      check_ok "Python modülü hazır: $mod"
    else
      check_warn "Python modülü eksik: $mod"
    fi
  done
else
  check_fail "Python sanal ortamı (~/.feride/venv) bulunamadı! 'bash kurulum.sh' çalıştırın."
fi

echo -e "\n${BLUE}4. Sabit Yol (Hardcoded Path) Denetimi:${NC}"
HARDCODED=$(grep -rnI --exclude="feride_doctor.sh" "/home/" "$APP_DIR/lib" "$APP_DIR/scripts" "$APP_DIR/kurulum.sh" "$APP_DIR/run.sh" "$APP_DIR/mcp_config.json" 2>/dev/null | wc -l)
if [ "$HARDCODED" -eq 0 ]; then
  check_ok "Sıfır sabit kullanıcı yolu (/home/... yok — %100 taşınabilir)"
else
  check_fail "$HARDCODED adet sabit kullanıcı yolu bulundu!"
fi

echo -e "\n${BLUE}================================================================${NC}"
echo -e "Sonuç: ${GREEN}${PASS} Başarılı${NC} | ${YELLOW}${WARN} Uyarı${NC} | ${RED}${FAIL} Hata${NC}"
echo -e "${BLUE}================================================================${NC}"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
