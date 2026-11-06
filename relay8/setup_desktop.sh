#!/usr/bin/env bash
# USBRelay8 kurulumu: kalici erisim izni + masaustu kisa yolu
set -e
cd "$(dirname "$0")"

echo "=== 1) udev kuralini kopyala (parolasiz erisim) ==="
cp udev_rule.rules /etc/udev/rules.d/99-usbreelay8.rules
sudo -A udevadm control --reload-rules
sudo -A udevadm trigger
echo "   udev kurali kuruldu. Karti cek-birakman gerekebilir."

echo
echo "=== 2) Masaustu kisa yolunu olustur ==="
DESK="$HOME/Desktop"
[ -d "$DESK" ] || DESK="$HOME/Artifacts"
[ -d "$DESK" ] || DESK="$HOME"
cp USBRelay8.desktop "$DESK/USBRelay8.desktop"
chmod +x "$DESK/USBRelay8.desktop"
# Bazilar masaustu icin .desktop'a 'trusted' isareti ister
gio set "$DESK/USBRelay8.desktop" metadata::trusted true 2>/dev/null || true
echo "   Kisa yol: $DESK/USBRelay8.desktop"

echo
echo "=== 3) Python betigini calistirilabilir yap ==="
chmod +x relay8.py

echo
echo "=== 4) Cihaz izinlerini kontrol et ==="
ls -l /dev/hidraw* 2>/dev/null | grep -E "hidraw" | head
echo
echo "BAŞARILI. Masaüstünde 'USBRelay8 Kontrol' kısayolunu çift tıkla."
echo "Not: kartı çek-birak edersen izinler udev kuralıyla otomatik gelir."
