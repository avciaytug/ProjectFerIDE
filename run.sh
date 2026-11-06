#!/usr/bin/env bash
# ==============================================================================
#  FerIDE Beta v5.3.6 — Otonom Başlatıcı (run.sh)
#  Klasör nereye taşınırsa taşınsın (veya exFAT/USB yedekten yeni çıkarsa bile)
#  çalıştırma izinlerini, .so bağlarını ve ~/.feride ortamını kendi kendine
#  onarıp FerIDE'yi anında başlatır.
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1

export FERIDE_ROOT="$DIR"
FERIDE_HOME="$HOME/.feride"

mkdir -p "$FERIDE_HOME"/{models,models/mmproj,aegis,skills,todos,Chats,logs,bin,tmp}
mkdir -p "$DIR/models/mmproj" "$DIR/Chats"
[ -d "$DIR/models/whisper" ] && chmod -R u+rwX "$DIR/models/whisper" 2>/dev/null || true

# 1. USB / exFAT / ZIP'ten çıkarma sonrası izin ve .so sembolik bağlarını anında onar
BUNDLE_DIR="$DIR/build/linux/x64/release/bundle"
BUNDLE_BIN="$BUNDLE_DIR/feride_v5_2"

[ -f "$BUNDLE_BIN" ] && [ ! -x "$BUNDLE_BIN" ] && chmod +x "$BUNDLE_BIN" 2>/dev/null || true
# dash (/bin/sh) uyumluluk katmanı: model motoru başlatıcısı için bin/sh -> bash
[ -f "$DIR/bin/sh" ] && [ ! -x "$DIR/bin/sh" ] && chmod +x "$DIR/bin/sh" 2>/dev/null || true
if [ -d "$DIR/bin/cad" ]; then
  for f in "$DIR/bin/cad/"*; do
    [ -f "$f" ] && [ ! -x "$f" ] && chmod +x "$f" 2>/dev/null || true
  done
fi

fix_llama_dir() {
  local ldir="$1"
  [ -d "$ldir" ] || return 0
  [ -f "$ldir/llama-server" ] && [ ! -x "$ldir/llama-server" ] && chmod +x "$ldir/"llama-* 2>/dev/null || true
  [ -f "$ldir/llama-server.real" ] && [ ! -x "$ldir/llama-server.real" ] && chmod +x "$ldir/llama-server.real" 2>/dev/null || true
  (
    cd "$ldir" || exit 0
    for full in lib*.so.*.*.*; do
      [ -f "$full" ] || continue
      base="${full%%.so.*}.so"
      rest="${full#*.so.}"
      major="${rest%%.*}"
      soname="${base}.${major}"
      [ -e "$soname" ] || ln -sf "$full" "$soname" 2>/dev/null || cp -f "$full" "$soname" 2>/dev/null || true
      [ -e "$base" ]   || ln -sf "$soname" "$base" 2>/dev/null || cp -f "$full" "$base" 2>/dev/null || true
    done
  )
}
fix_llama_dir "$DIR/bin/llama-cpp"
fix_llama_dir "$FERIDE_HOME/bin/llama-cpp"

# Gömülü Vulkan GPU llama-server'ı kullanıcı dizinine senkronize et
if [ -d "$DIR/bin/llama-cpp" ]; then
  mkdir -p "$FERIDE_HOME/bin/llama-cpp"
  if [ ! -f "$FERIDE_HOME/bin/llama-cpp/libggml-vulkan.so" ] && [ -f "$DIR/bin/llama-cpp/libggml-vulkan.so" ]; then
    cp -a "$DIR/bin/llama-cpp/"* "$FERIDE_HOME/bin/llama-cpp/"
    fix_llama_dir "$FERIDE_HOME/bin/llama-cpp"
  fi
fi

# Ubuntu/Kubuntu 26.10+ (OpenSSL 4) uyumluluğu: gömülü OpenSSL 3 (.so.3) kütüphanelerini kullanıcı dizinine de yansıt
if [ -d "$FERIDE_HOME/bin/llama-cpp" ]; then
  for ssl_so in libssl.so.3 libcrypto.so.3; do
    if [ -f "$DIR/bin/llama-cpp/$ssl_so" ] && [ ! -e "$FERIDE_HOME/bin/llama-cpp/$ssl_so" ]; then
      ln -sf "$DIR/bin/llama-cpp/$ssl_so" "$FERIDE_HOME/bin/llama-cpp/$ssl_so" 2>/dev/null || \
        cp -f "$DIR/bin/llama-cpp/$ssl_so" "$FERIDE_HOME/bin/llama-cpp/$ssl_so" 2>/dev/null || true
    fi
  done
fi

# 2. İlk çalıştırmada dahili mmproj, yetenekler ve Aegis verilerini senkronize et
if [ -d "$DIR/models/mmproj" ]; then
  for mm in "$DIR/models/mmproj"/*.gguf; do
    [ -f "$mm" ] || continue
    tmm="$FERIDE_HOME/models/mmproj/$(basename "$mm")"
    [ -e "$tmm" ] || ln -sf "$mm" "$tmm" 2>/dev/null || cp -f "$mm" "$tmm" 2>/dev/null || true
  done
fi

if [ -d "$DIR/skills_data" ]; then
  if [ -z "$(ls -A "$FERIDE_HOME/skills" 2>/dev/null)" ]; then
    cp -rf "$DIR/skills_data/"* "$FERIDE_HOME/skills/" 2>/dev/null || true
  elif [ -d "$DIR/skills_data/universal-file-and-cad-studio" ] && [ ! -d "$FERIDE_HOME/skills/universal-file-and-cad-studio" ]; then
    cp -rf "$DIR/skills_data/universal-file-and-cad-studio" "$FERIDE_HOME/skills/" 2>/dev/null || true
  fi
fi

if [ -f "$DIR/aegis_data/memory.db" ] && [ ! -f "$FERIDE_HOME/aegis/memory.db" ]; then
  cp -f "$DIR/aegis_data/memory.db" "$FERIDE_HOME/aegis/memory.db" 2>/dev/null || true
fi

if [ -f "$DIR/mcp_config.json" ] && [ ! -f "$FERIDE_HOME/mcp_config.json" ]; then
  cp -f "$DIR/mcp_config.json" "$FERIDE_HOME/mcp_config.json" 2>/dev/null || true
fi

# 3. Kullanıcı kurulum.sh çalıştırmadan doğrudan tıkladıysa Python venv'i arka planda sessizce hazırla
if [ ! -x "$FERIDE_HOME/venv/bin/python3" ] && [ -f "$DIR/scripts/feride_env_setup.sh" ]; then
  if python3 -m venv --help >/dev/null 2>&1; then
    nohup bash "$DIR/scripts/feride_env_setup.sh" >> "$FERIDE_HOME/logs/env_bootstrap.log" 2>&1 &
  fi
fi

# 4. Ortam değişkenlerini (LD_LIBRARY_PATH + PATH) yapılandır
GTK_LOCAL_LIB="$HOME/opt/gtkdev/extracted/usr/lib/x86_64-linux-gnu"
EXTRA_LD="$BUNDLE_DIR/lib:$DIR/bin/llama-cpp:$FERIDE_HOME/bin/llama-cpp"
if [ -d "$GTK_LOCAL_LIB" ]; then
  EXTRA_LD="$EXTRA_LD:$GTK_LOCAL_LIB"
fi
export LD_LIBRARY_PATH="$EXTRA_LD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$DIR/bin:$DIR/bin/llama-cpp:$DIR/bin/cad:$FERIDE_HOME/bin:$FERIDE_HOME/bin/llama-cpp:$FERIDE_HOME/venv/bin:$HOME/opt/flutter/bin:$HOME/flutter/bin:$PATH"

# 5. Derlenmiş Release uygulamasını başlat (eksik kütüphane varsa kurulum sihirbazına yönlendir)
if [ -x "$BUNDLE_BIN" ]; then
  if ! ldd "$BUNDLE_BIN" 2>&1 | grep -q "not found"; then
    exec "$BUNDLE_BIN" "$@"
  else
    echo "[FerIDE] Eksik sistem kütüphaneleri tespit edildi, otonom kurulum başlatılıyor..."
    bash "$DIR/kurulum.sh"
    exec "$BUNDLE_BIN" "$@"
  fi
fi

# Yedek: Release binary yoksa ve Flutter kuruluysa derleyip başlat
if command -v flutter >/dev/null 2>&1; then
  flutter build linux --release && exec "$BUNDLE_BIN" "$@"
fi

echo "HATA: Çalıştırılabilir FerIDE paketi bulunamadı. Lütfen önce 'bash kurulum.sh' çalıştırın." >&2
exit 1
