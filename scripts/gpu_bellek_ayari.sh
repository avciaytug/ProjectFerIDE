#!/usr/bin/env bash
# ==============================================================================
#  FerIDE — AMD APU (Ryzen AI Max / Strix Halo, 780M/890M vb.) GPU bellek sınırı
# ------------------------------------------------------------------------------
#  Paylaşımlı bellekli AMD işlemcilerde GPU'nun kullanabileceği bellek (GTT),
#  Linux çekirdeğinde varsayılan olarak RAM'in YARISIYLA sınırlıdır. 128 GB'lık
#  bir makinede bu ~62 GB demektir; GLM-4.5-Air gibi büyük modeller sığmaz ve
#  GPU belleği dolunca masaüstü uygulamaları çöker.
#
#  Bu betik çekirdek açılış parametrelerine ttm.pages_limit / ttm.page_pool_size
#  ekleyerek sınırı "RAM - 12 GB"a (ör. 124 GB → 112 GB) yükseltir.
#  Ana GRUB dosyasına dokunmaz: ayrı bir dosya ekler
#  (/etc/default/grub.d/99-feride-gpu-bellek.cfg); geri almak = o dosyayı silmek.
#
#  Kullanım:
#    sudo bash scripts/gpu_bellek_ayari.sh            # öneriyi uygula (onay ister)
#    sudo bash scripts/gpu_bellek_ayari.sh 100        # sınırı 100 GiB yap
#    sudo bash scripts/gpu_bellek_ayari.sh --geri-al  # eski ayara dön
#  Değişiklik bilgisayar yeniden başlatılınca etkinleşir.
# ==============================================================================
set -euo pipefail

DROPIN_DIR=/etc/default/grub.d
DROPIN="$DROPIN_DIR/99-feride-gpu-bellek.cfg"
die() { echo "HATA: $*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "Bu ayar yalnızca Linux içindir."
[ "$(id -u)" -eq 0 ] || die "Bu betik yönetici yetkisi ister: sudo bash $0 ${*:-}"

# grub-mkconfig, /etc/default/grub'ı "set -e" ile okur (ayrı bir sh süreciyle taklit
# edilir: "if ( set -e; … )" içinde set -e etkisiz kalır): dosyadaki tek bir hatalı
# satır (ör. satır başına yanlışlıkla yazılmış "xx#") update-grub'ı tamamen durdurur.
check_grub_file() {
  local f=/etc/default/grub
  [ -f "$f" ] || return 0
  if sh -ec '. "$1"' sh "$f" >/dev/null 2>&1; then return 0; fi
  echo "UYARI: $f okunurken hata veriyor; bu haliyle update-grub çalışmaz."
  local bad
  bad=$(grep -nE '^[^#[:space:]=]+#' "$f" | head -1 || true)
  [ -n "$bad" ] || die "$f hatalı; dosyayı elle kontrol edin (örn. sudo nano $f)."
  echo "  Sorunlu satır  → $bad"
  echo "  Düzeltilmiş hali → $(echo "${bad#*:}" | sed -E 's/^[^#[:space:]=]+#/#/')"
  if [ "${FERIDE_EVET:-}" != "1" ]; then
    read -r -p "  Satır başındaki fazladan karakterler silinsin mi? (yedek alınır) (e/H) " a
    case "$a" in e|E|evet|Evet) ;; *) die "Önce $f dosyasını düzeltin.";; esac
  fi
  cp -a "$f" "$f.feride-yedek-$(date +%Y%m%d-%H%M%S)"
  sed -i -E 's/^[^#[:space:]=]+#/#/' "$f"
  sh -ec '. "$1"' sh "$f" >/dev/null 2>&1 || die "$f hâlâ hatalı; elle kontrol edin."
  echo "  ✓ $f düzeltildi (yedek alındı)."
}

regen_grub() {
  check_grub_file
  if command -v update-grub >/dev/null 2>&1; then update-grub
  elif command -v grub2-mkconfig >/dev/null 2>&1; then grub2-mkconfig -o /boot/grub2/grub.cfg
  elif command -v grub-mkconfig >/dev/null 2>&1; then grub-mkconfig -o /boot/grub/grub.cfg
  else die "GRUB yapılandırması yenilenemedi (update-grub / grub-mkconfig bulunamadı)."; fi
}

if [ "${1:-}" = "--geri-al" ]; then
  if [ -f "$DROPIN" ]; then
    rm -f "$DROPIN"
    regen_grub
  elif command -v grubby >/dev/null 2>&1; then
    grubby --update-kernel=ALL --remove-args="ttm.pages_limit ttm.page_pool_size"
  else
    die "Kaldırılacak FerIDE ayarı bulunamadı."
  fi
  echo "✓ GPU bellek sınırı varsayılana döndürüldü. Bilgisayarı yeniden başlatın."
  exit 0
fi

card=""
for c in /sys/class/drm/card*/device; do
  if [ -f "$c/mem_info_gtt_total" ] && [ -f "$c/mem_info_vram_total" ]; then card="$c"; break; fi
done
[ -n "$card" ] || die "AMD GPU (amdgpu) bulunamadı."
vram_mib=$(( $(cat "$card/mem_info_vram_total") / 1048576 ))
gtt_mib=$(( $(cat "$card/mem_info_gtt_total") / 1048576 ))
[ "$vram_mib" -le 8192 ] || die "Ayrık ekran kartı bulundu ($vram_mib MiB VRAM). Bu ayar yalnızca paylaşımlı bellekli APU'lar içindir."

ram_gib=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1048576 ))
target_gib="${1:-$(( ram_gib - 12 ))}"
[[ "$target_gib" =~ ^[0-9]+$ ]] || die "Geçersiz değer: $target_gib (GiB cinsinden tam sayı verin)"
if [ "$target_gib" -lt 8 ] || [ "$target_gib" -gt $(( ram_gib - 6 )) ]; then
  die "Sınır 8 ile $(( ram_gib - 6 )) GiB arasında olmalı (işletim sistemine en az 6 GiB kalmalı)."
fi
pages=$(( target_gib * 262144 ))   # 4 KiB sayfa
params="ttm.pages_limit=$pages ttm.page_pool_size=$pages"

echo "RAM: ${ram_gib} GiB | Şu anki GPU sınırı (GTT): $(( gtt_mib / 1024 )) GiB | Yeni sınır: ${target_gib} GiB"
echo "Eklenecek açılış parametreleri: $params"
if [ "${FERIDE_EVET:-}" != "1" ]; then
  read -r -p "Uygulansın mı? (e/H) " ans
  case "$ans" in e|E|evet|Evet) ;; *) echo "İptal edildi."; exit 0;; esac
fi

# Bir şey yazmadan önce GRUB dosyasının okunabildiğinden emin ol.
check_grub_file

if [ -d "$DROPIN_DIR" ]; then
  # Debian / Ubuntu / Kubuntu: grub.d ek dosyası (ana dosyaya dokunulmaz).
  printf '# FerIDE: AMD APU GPU bellek sınırı (%s GiB). Geri almak için bu dosyayı silip update-grub çalıştırın.\nGRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT %s"\n' \
    "$target_gib" "$params" > "$DROPIN"
  regen_grub
elif command -v grubby >/dev/null 2>&1; then
  # Fedora / RHEL: BLS girdileri grubby ile güncellenir.
  grubby --update-kernel=ALL --remove-args="ttm.pages_limit ttm.page_pool_size"
  grubby --update-kernel=ALL --args="$params"
else
  die "Desteklenmeyen önyükleyici. Çekirdek açılış parametrelerine elle ekleyin: $params"
fi

echo ""
echo "✓ Tamam. Bilgisayarı yeniden başlatın; ardından FerIDE büyük modelleri tamamen GPU'da çalıştırabilir."
echo "  Geri almak için: sudo bash $0 --geri-al"
