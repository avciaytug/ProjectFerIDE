#!/usr/bin/env bash
# FerIDE Beta v5.3.4 — Hızlı Başlatıcı
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$DIR/run.sh" 2>/dev/null || true
exec "$DIR/run.sh" "$@"
