#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
USBRelay8 (dcttech, 16c0:05df) — HID protokolunu cozucu / test araci
===================================================================
Bu kart USB-SERI degil, dogrudan USB-HID (hidraw) konusur.
Oncelikle report descriptor'u okuyup rapor formatini cikarir,
ardindan 8 roleyi ac/kapa yapacak test modlarini calistirir.

KULLANIM:
    # 1) Sadece protokol coz (descriptor + rapor boyutu):
        python3 usbrelay8_probe.py probe

    # 2) Otomatik sirali ac-kapa testi (hepsi ac, hepsi kapat, 1-8 tek tek):
        python3 usbrelay8_probe.py auto

    # 3) Etkilesimli (menu):
        python3 usbrelay8_probe.py

    # Belirli hidraw cihazini zorla:
        python3 usbrelay8_probe.py --dev /dev/hidraw14 auto

NOT: /dev/hidrawXX root'a aitse 'sudo' ile calistir veya
     udev_rule.rules'i kur.
"""

import sys, os, time, struct, argparse, glob

# ----------------------------------------------------------------------
# HID ioctl sabitleri (Linux)
# ----------------------------------------------------------------------
HIDGCREPORT = 0x5005   # GET_REPORT (report descriptor)
HIDGCSIZE   = 0x5071   # GET_SIZE

def find_relay_dev(hint=None):
    """USBRelay8'e karsilik gelen /dev/hidrawX'i bul."""
    if hint:
        return hint
    # sysfs'ten 16c0:05df -> hidrawX eslesmesi
    for h in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        dev = os.path.realpath(os.path.join(h, "device"))
        # yol 0003:16C0:05DF.0011 gibi
        if "16C0:05DF" in dev.upper():
            idx = os.path.basename(h).replace("hidraw", "")
            return f"/dev/hidraw{idx}"
    return None

def open_dev(path):
    try:
        fd = os.open(path, os.O_RDWR)
        return fd
    except PermissionError:
        print(f"[!] {path} erisim reddi. 'sudo' ile calistir veya udev kuralini kur.")
        raise

def read_report_descriptor(fd):
    buf = bytearray(512)
    import fcntl
    fcntl.ioctl(fd, HIDGCREPORT, buf)
    # descriptor: 0x06 (Usage Page) ... sonundaki 0x00 (End of Descriptor)
    end = buf.find(0x00, 2)
    if end < 0:
        end = len(buf)
    return bytes(buf[:end+1])

def parse_report_descriptor(rd):
    """Basit HID report descriptor parser -> (report_id, total_bits) listesi."""
    i = 0
    reports = []
    cur_usage_page = 0
    cur_report_id = 0
    cur_usage_min = 0
    cur_usage_max = 0
    cur_log_min = 0
    cur_log_max = 0
    cur_report_size = 1
    cur_report_count = 1
    cur_phys = 0
    in_input = False
    pending_bits = 0
    while i < len(rd):
        b = rd[i]
        # main items: b7b6 == 00
        if (b & 0xC0) == 0x00:
            # short item
            if b == 0x04:  # reserved
                i += 1; continue
            # tag 4-bit, size 2-bit
            tag = b & 0x0F
            size = (b >> 4) & 0x03
            lens = [1, 2, 4, 7][size]
            val = int.from_bytes(rd[i+1:i+1+lens], "little")
            i += 1 + lens
            if tag == 0x04: cur_report_id = val
            elif tag == 0x05: cur_usage_page = val
            elif tag == 0x19: cur_usage_min = val
            elif tag == 0x29: cur_usage_max = val
            elif tag == 0x75: cur_report_size = val
            elif tag == 0x95: cur_report_count = val
            elif tag == 0x85: cur_report_id = val
            elif tag == 0x81:  # Input
                bits = cur_report_size * cur_report_count
                reports.append(("IN", cur_report_id, bits, cur_usage_page))
                cur_report_size = 1; cur_report_count = 1
            elif tag == 0x82:  # Output
                bits = cur_report_size * cur_report_count
                reports.append(("OUT", cur_report_id, bits, cur_usage_page))
                cur_report_size = 1; cur_report_count = 1
            elif tag == 0x80:  # Feature
                bits = cur_report_size * cur_report_count
                reports.append(("FEAT", cur_report_id, bits, cur_usage_page))
                cur_report_size = 1; cur_report_count = 1
        else:
            i += 1
    return reports

# ----------------------------------------------------------------------
# Komutlar
# ----------------------------------------------------------------------
def do_probe(dev):
    fd = open_dev(dev)
    try:
        rd = read_report_descriptor(fd)
        print(f"Report descriptor ({len(rd)} byte):")
        print("  " + rd.hex(" "))
        reps = parse_report_descriptor(rd)
        print("\nParce edilmis raporlar:")
        total_out = 0
        for kind, rid, bits, upage in reps:
            print(f"  {kind:4s} report_id={rid}  bits={bits}  usage_page=0x{upage:02x}  bytes={bits//8}")
            if kind == "OUT":
                total_out += bits
        # Rapor boyutu tahmini: en buyuk input/feature
        sizes = [b for k,r,b,u in reps]
        print(f"\nToplam OUT bits: {total_out}  ->  {total_out//8} byte")
        print("\n>>> Bu karti kontrol etmek icin bir OUT (veya FEATURE) raporu gondermeniz gerekir.")
        print(">>> Rapor formatini belirlemek icin ayni kartin diger bir surucusu/dokumantasyonu gerekir.")
        print(">>> Deneysel olarak 1 byte / 2 byte / 4 byte / 8 byte maskeler denenebilir.")
    finally:
        os.close(fd)
    return reps

def write_report(fd, report_id, data):
    """HID output raporu yazar. report_id 0 ise data dogrudan."""
    import fcntl
    if report_id:
        payload = bytes([report_id]) + data
    else:
        payload = data
    os.write(fd, payload)

def do_auto(dev, reps):
    """Otomatik sirali ac-kapa testi.
    Rapor formati bilinmedigi icin en yaygin USBRelay8 davranisini dener:
      - 1 byte mask (bit N = role N)  VEYA
      - 2 byte (byte0=komut, byte1=mask)  VEYA
      - 8 byte (her byte bir role, 0xFF=ac 0x00=kapat)
    Kartin LED'lerine bakarak hangisinin isledigini gorebilirsin.
    """
    fd = open_dev(dev)
    try:
        print("\n=== OTOMATIK SIRALI AC-KAPA TESTI ===")
        print("Kartin LED'lerine bak: hangi strateji isliyorsa o dogru formattir.")
        # Strateji 1: 1 byte mask, bit0=role1 ... bit7=role8
        for name, build in [
            ("1-byte mask (bit N=role N)", lambda on: bytes([sum(1<<i for i in range(8) if (on>>i)&1)])),
            ("2-byte (cmd=1, mask)",       lambda on: bytes([0x01, sum(1<<i for i in range(8) if (on>>i)&1)])),
            ("8-byte (0xFF=ac,0x00=kapat)",lambda on: bytes([0xFF if (on>>i)&1 else 0x00 for i in range(8)])),
        ]:
            print(f"\n-- Strateji: {name} --")
            # hepsi ac
            write_report(fd, 0, build(0xFF)); time.sleep(1.0)
            print("   hepsi ACIK  (1 sn)")
            # hepsi kapat
            write_report(fd, 0, build(0x00)); time.sleep(1.0)
            print("   hepsi KAPALI (1 sn)")
            # tek tek
            for ch in range(1, 9):
                write_report(fd, 0, build(1 << (ch-1))); time.sleep(0.5)
                print(f"   role {ch} ACIK (0.5 sn)")
            write_report(fd, 0, build(0x00)); time.sleep(0.5)
            print("   hepsi kapatildi")
    finally:
        os.close(fd)

def interactive(dev, reps):
    fd = open_dev(dev)
    try:
        print("\nEtkilesimli mod. Komutlar:")
        print("  on  <N...>   role(ler)i ac   (ornek: on 1 3 4)")
        print("  off <N...>   role(ler)i kapat")
        print("  allon / alloff")
        print("  auto         otomatik sirali test")
        print("  raw  <hex>   ham byte gonder (ornek: raw FF)")
        print("  q            cikis")
        def mask_on(chans): return bytes([sum(1<<(c-1) for c in chans)])
        def mask_off(chans): return bytes([0])
        while True:
            try:
                line = input("relay> ").strip().split()
            except (EOFError, KeyboardInterrupt):
                break
            if not line: continue
            cmd = line[0].lower()
            if cmd == "q": break
            elif cmd == "on":
                chans = [int(x) for x in line[1:]]
                write_report(fd, 0, mask_on(chans)); print("  acildi:", chans)
            elif cmd == "off":
                write_report(fd, 0, mask_off([int(x) for x in line[1:]])); print("  kapatildi")
            elif cmd == "allon":
                write_report(fd, 0, bytes([0xFF])); print("  hepsi acik")
            elif cmd == "alloff":
                write_report(fd, 0, bytes([0x00])); print("  hepsi kapali")
            elif cmd == "auto":
                do_auto(dev, reps)
            elif cmd == "raw":
                data = bytes.fromhex("".join(line[1:]))
                write_report(fd, 0, data); print("  gonderildi:", data.hex())
            else:
                print("  bilinmeyen komut")
    finally:
        os.close(fd)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", help="/dev/hidrawX zorla")
    ap.add_argument("mode", nargs="?", default="probe",
                    choices=["probe", "auto", "interactive"])
    a = ap.parse_args()
    dev = find_relay_dev(a.dev)
    if not dev:
        print("[!] USBRelay8 (16c0:05df) bulunamadi. Karti bagladindan emin ol.")
        print("    lsusb | grep -i 16c0  ile kontrol et.")
        sys.exit(1)
    print(f"Kart cihaz: {dev}")
    reps = do_probe(dev)
    if a.mode == "auto":
        do_auto(dev, reps)
    elif a.mode == "interactive":
        interactive(dev, reps)

if __name__ == "__main__":
    main()
