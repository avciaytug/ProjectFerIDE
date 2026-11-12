#!/usr/bin/env bash
# FerIDE kurulumu (Linux / macOS).
#   curl -fsSL https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.sh | bash
# Paketi indirip doğrular ve FerIDE kurulum sihirbazını açar: programın ve verilerin (modeller, sohbetler)
# nereye kurulacağını siz seçersiniz (ev klasörü, başka bir disk bölümü, /mnt/... gibi). FerIDE zaten kuruluysa
# yerinde güncellenir. Masaüstü oturumu yoksa (SSH, sunucu) sihirbaz açılmaz, varsayılan konumlara kurulur.
# Linux'ta pencere için gereken sistem kitaplıkları eksikse TEK bir sudo onayıyla kurulur.
# Kaldırmak için: feride uninstall (ya da FerIDE'de Ayarlar > Genel > Kaldır).
#
# Sihirbazsız kurulum için isteğe bağlı ortam değişkenleri:
#   FERIDE_INSTALL_DIR   program klasörü (bu ya da FERIDE_DATA_DIR verilirse sihirbaz açılmaz)
#   FERIDE_DATA_DIR      veri klasörü: modeller, sohbetler, ayarlar (varsayılan: ~/.feride)
#   FERIDE_NO_SHORTCUTS  1 ise uygulama menüsü/masaüstü kısayolu ve ~/.local/bin/feride oluşturulmaz
#   FERIDE_NO_LAUNCH     1 ise kurulumdan sonra FerIDE açılmaz
set -euo pipefail

REPO="avciaytug/ProjectFerIDE"
OS="$(uname -s)"
PS_INSTALL="irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex"

# Windows'ta (Git Bash / MSYS / Cygwin) çalıştırıldıysa Windows kurulumuna geç.
case "$OS" in
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows algılandı; FerIDE'nin Windows sürümü kuruluyor…"
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$PS_INSTALL" ;;
esac
# PowerShell'den "| bash" ile çağrılınca bash çoğu zaman WSL'dir: Linux sürümünü WSL'nin içine kurmak yerine
# Windows sürümünü kur. WSL içinde Linux sürümü isteniyorsa: FERIDE_WSL_LINUX=1
if [ "$OS" = Linux ] && grep -qi microsoft /proc/version 2>/dev/null && [ "${FERIDE_WSL_LINUX:-}" != 1 ] \
  && command -v powershell.exe >/dev/null 2>&1; then
  echo "WSL algılandı; FerIDE'nin Windows sürümü kuruluyor (WSL içine Linux sürümü için: FERIDE_WSL_LINUX=1)…"
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$PS_INSTALL"
fi

ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH=x64 ;; arm64|aarch64) ARCH=arm64 ;; *) echo "Desteklenmeyen mimari: $ARCH"; exit 1 ;; esac
case "$OS" in
  Linux) PLAT=linux; POINTER="${XDG_CONFIG_HOME:-$HOME/.config}/feride/install.json" ;;
  Darwin) PLAT=macos; POINTER="$HOME/Library/Application Support/FerIDE/install.json" ;;
  *) echo "Desteklenmeyen sistem: $OS"; exit 1 ;;
esac
ASSET="feride-$PLAT-$ARCH.tar.gz"

say() { printf '\033[36m%s\033[0m\n' "$*"; }

if [ "$PLAT" = linux ]; then
  # WebKitGTK (arayüz penceresi) var mı?
  if ! ldconfig -p 2>/dev/null | grep -q "libwebkit2gtk-4.1.so"; then
    say "Arayüz için WebKitGTK gerekiyor; tek seferlik yönetici onayı istenecek."
    if command -v apt-get >/dev/null; then sudo apt-get update && sudo apt-get install -y libwebkit2gtk-4.1-0 libgtk-3-0 libxdo3 git
    elif command -v dnf >/dev/null; then sudo dnf install -y webkit2gtk4.1 gtk3 libxdo git
    elif command -v pacman >/dev/null; then sudo pacman -S --needed --noconfirm webkit2gtk-4.1 gtk3 xdotool git
    elif command -v zypper >/dev/null; then sudo zypper --non-interactive install libwebkit2gtk-4_1-0 gtk3 git
    else echo "Paket yöneticisi bulunamadı; webkit2gtk-4.1 kurun ya da 'feride serve --open' kullanın."; fi
  fi
fi

say "FerIDE sürümü sorgulanıyor…"
URL="$(curl -fsSL -H 'User-Agent: FerIDE-installer' "https://api.github.com/repos/$REPO/releases?per_page=20" \
  | grep -o "\"browser_download_url\": *\"[^\"]*/$ASSET\"" | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "$URL" ] || { echo "Bu platform için sürüm bulunamadı ($ASSET)."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "İndiriliyor: $URL"
curl -fL --progress-bar "$URL" -o "$TMP/$ASSET"
if curl -fsSL "$URL.sha256" -o "$TMP/sum" 2>/dev/null; then
  EXPECTED="$(cut -d' ' -f1 < "$TMP/sum")"
  ACTUAL="$( (command -v sha256sum >/dev/null && sha256sum "$TMP/$ASSET" || shasum -a 256 "$TMP/$ASSET") | cut -d' ' -f1)"
  [ "$EXPECTED" = "$ACTUAL" ] || { echo "İndirme doğrulanamadı (SHA-256)."; exit 1; }
  say "SHA-256 doğrulandı."
fi

mkdir -p "$TMP/paket"
tar -xzf "$TMP/$ASSET" -C "$TMP/paket"
chmod +x "$TMP/paket/feride"
if [ "$PLAT" = macos ]; then xattr -dr com.apple.quarantine "$TMP/paket" 2>/dev/null || true; fi

# Kurulumu FerIDE'nin kendisi yapar: program/veri klasörü, kısayollar, ~/.local/bin/feride.
ARGS=(install)
GUI=0
if [ "$PLAT" = macos ] || [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then GUI=1; fi
if [ -n "${FERIDE_INSTALL_DIR:-}" ] || [ -n "${FERIDE_DATA_DIR:-}" ]; then
  ARGS+=(--yes)
  if [ -n "${FERIDE_INSTALL_DIR:-}" ]; then ARGS+=(--dir "$FERIDE_INSTALL_DIR"); fi
  if [ -n "${FERIDE_DATA_DIR:-}" ]; then ARGS+=(--data "$FERIDE_DATA_DIR"); fi
  if [ "${FERIDE_NO_SHORTCUTS:-}" = 1 ]; then ARGS+=(--no-shortcuts --no-path); fi
  say "Kuruluyor…"
elif [ "$GUI" = 1 ]; then
  # Kuruluysa yerinde güncellenir; değilse kurulum sihirbazı açılır.
  ARGS+=(--update)
  say "Kurulum sihirbazı açılıyor: FerIDE'nin ve verilerinin kurulacağı yeri seçin… (kuruluysa doğrudan güncellenir)"
else
  # Masaüstü oturumu yok: kuruluysa güncelle, değilse varsayılan konumlara kur.
  ARGS+=(--update --yes)
  if [ "${FERIDE_NO_SHORTCUTS:-}" = 1 ]; then ARGS+=(--no-shortcuts --no-path); fi
  say "Masaüstü oturumu yok; varsayılan konumlara kuruluyor (yer seçmek için FERIDE_INSTALL_DIR / FERIDE_DATA_DIR)."
fi
if [ "${FERIDE_NO_LAUNCH:-}" = 1 ] || [ "$GUI" = 0 ]; then ARGS+=(--no-launch); fi

set +e
"$TMP/paket/feride" "${ARGS[@]}" </dev/null
CODE=$?
set -e
case "$CODE" in
  0) ;;
  2) echo "Kurulum iptal edildi; bilgisayarınızda bir değişiklik yapılmadı."; exit 0 ;;
  *) echo "Kurulum başarısız oldu (çıkış kodu $CODE). Ayrıntılar: ${TMPDIR:-/tmp}/feride-kurulum.log"; exit 1 ;;
esac

say "FerIDE kuruldu."
if [ -f "$POINTER" ]; then
  get() { sed -n "s/.*\"$1\": *\"\(.*\)\".*/\1/p" "$POINTER" | head -1; }
  echo "  Program: $(get install_dir)"
  echo "  Veriler: $(get data_dir)"
fi
echo "Kaldırmak için: feride uninstall"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Not: ~/.local/bin PATH'inizde değil; 'feride' komutu için kabuk ayarınıza ekleyin." ;; esac
if [ "$GUI" = 0 ]; then echo "Sunucu olarak çalıştırmak için: feride serve (tarayıcıdan bağlanılır)"; fi
