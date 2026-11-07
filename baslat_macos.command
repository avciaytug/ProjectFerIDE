#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
export FERIDE_ROOT="$DIR"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.feride/bin/llama-cpp:$HOME/.feride/venv/bin:$PATH"

# Xcode ürün adı (feride_v4) Linux/Windows ikili adından farklı; adı ne olursa olsun bul.
find_app() {
  MAC_APP="$(ls -d "$DIR"/build/macos/Build/Products/Release/*.app 2>/dev/null | head -n 1)"
  MAC_BIN=""
  [ -n "$MAC_APP" ] && MAC_BIN="$MAC_APP/Contents/MacOS/$(basename "$MAC_APP" .app)"
}
find_app

if [ -n "$MAC_BIN" ] && [ -x "$MAC_BIN" ]; then
  xattr -cr "$MAC_APP" 2>/dev/null || true
  exec "$MAC_BIN" "$@"
fi

if command -v flutter >/dev/null 2>&1; then
  echo "[FerIDE] macOS Release paketi derleniyor..."
  flutter pub get && flutter build macos --release && find_app && [ -x "$MAC_BIN" ] && exec "$MAC_BIN" "$@"
fi

echo "HATA: macOS uygulama paketi bulunamadı. Lütfen önce 'kurulum_macos.command' çalıştırın."
exit 1
