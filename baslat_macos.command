#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
export FERIDE_ROOT="$DIR"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.feride/bin/llama-cpp:$HOME/.feride/venv/bin:$PATH"

MAC_APP="$DIR/build/macos/Build/Products/Release/feride_v5_2.app"
MAC_BIN="$MAC_APP/Contents/MacOS/feride_v5_2"

if [ -x "$MAC_BIN" ]; then
  xattr -cr "$MAC_APP" 2>/dev/null || true
  exec "$MAC_BIN" "$@"
fi

if command -v flutter >/dev/null 2>&1; then
  echo "[FerIDE] macOS Release paketi derleniyor..."
  flutter pub get && flutter build macos --release && exec "$MAC_BIN" "$@"
fi

echo "HATA: macOS uygulama paketi bulunamadı. Lütfen önce 'kurulum_macos.command' çalıştırın."
exit 1
