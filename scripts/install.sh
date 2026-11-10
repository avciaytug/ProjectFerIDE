#!/usr/bin/env bash
# FerIDE kurulumu (Linux / macOS).
#   curl -fsSL https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.sh | bash
# Uygulama kullanıcı klasörüne kurulur. Linux'ta pencere için gereken sistem kitaplıkları
# eksikse TEK bir sudo onayıyla kurulur. Diğer her şeyi FerIDE ilk açılışta kendisi kurar.
set -euo pipefail

REPO="avciaytug/ProjectFerIDE"
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH=x64 ;; arm64|aarch64) ARCH=arm64 ;; *) echo "Desteklenmeyen mimari: $ARCH"; exit 1 ;; esac
case "$OS" in
  Linux) PLAT=linux; DEST="$HOME/.local/share/feride"; BIN="$HOME/.local/bin" ;;
  Darwin) PLAT=macos; DEST="$HOME/Applications/FerIDE"; BIN="$HOME/.local/bin" ;;
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
URL="$(curl -fsSL -H 'User-Agent: FerIDE-installer' "https://api.github.com/repos/$REPO/releases?per_page=10" \
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

mkdir -p "$DEST" "$BIN"
tar -xzf "$TMP/$ASSET" -C "$DEST"
chmod +x "$DEST/feride"
[ "$PLAT" = macos ] && xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
ln -sf "$DEST/feride" "$BIN/feride"

if [ "$PLAT" = linux ]; then
  mkdir -p "$HOME/.local/share/applications"
  cat > "$HOME/.local/share/applications/feride.desktop" <<EOF
[Desktop Entry]
Name=FerIDE
Comment=Yerel yapay zeka geliştirme ortamı
Exec=$DEST/feride
Terminal=false
Type=Application
Categories=Development;IDE;
EOF
fi

say "FerIDE kuruldu: $DEST  (komut: feride)"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Not: $BIN PATH'inizde değil; kabuk ayarınıza ekleyin." ;; esac
nohup "$DEST/feride" >/dev/null 2>&1 &
