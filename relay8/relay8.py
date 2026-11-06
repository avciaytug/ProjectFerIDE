#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
USBRelay8 (dcttech / Van Ooijen, 16c0:05df) — CANITLANMIS SURUCU
=================================================================
Bu kart OUTPUT report (os.write) DEGIL, FEATURE report (ioctl)
konusur. Komutlar 9 baytligidir:

      buf[0] = 0x00          # report ID
      buf[1] = KOMUT         # 0xFF=ACIK  0xFD=KAPALI  0xFE=HEPSI ACIK  0xFC=HEPSI KAPALI
      buf[2] = RELAY         # 1..8  (tumleri icin 0x00)
      buf[3..8] = 0x00

  YAZMA : fcntl.ioctl(fd, HIDIOCSFEATURE_9, buf)
  OKUMA : fcntl.ioctl(fd, HIDIOCGFEATURE_9, rep)  -> rep[8] = durum maskesi
          (bit N = role N+1)

Bu protokol, ayni kartla calisan RelayControlPro/relay_driver.py
kodundan birebir alinmis ve fiziksel olarak dogrulanmistir.
"""

import sys, os, glob, time, fcntl, struct, argparse, atexit

# ----------------------------------------------------------------------
# HID ioctl (Linux hidraw) — 9 baytlik feature report
# ----------------------------------------------------------------------
HIDIOCGRAWINFO   = 0x80084803   # _IOR('H', 0x03, 8)
HIDIOCSFEATURE_9 = 0xC0094806   # _IOWR('H', 0x06, 9)
HIDIOCGFEATURE_9 = 0xC0094807   # _IOWR('H', 0x07, 9)

REPORT_LEN  = 9
RELAY_COUNT = 8          # USBRelay8 -> 8 kanal

# Kart komutlari (relay_driver.py ile ayni)
CMD_ON      = 0xFF
CMD_OFF     = 0xFD
CMD_ALL_ON  = 0xFE
CMD_ALL_OFF = 0xFC

# ----------------------------------------------------------------------
# Cihaz bulma
# ----------------------------------------------------------------------
def find_relay_dev(hint=None):
    if hint:
        return hint
    for h in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            dev = os.path.realpath(os.path.join(h, "device"))
        except OSError:
            continue
        if "16C0:05DF" in dev.upper():
            idx = os.path.basename(h).replace("hidraw", "")
            return f"/dev/hidraw{idx}"
    return None


def open_dev(path):
    try:
        fd = os.open(path, os.O_RDWR)
    except PermissionError:
        print(f"[!] {path} erisim reddi. 'sudo' ile calistir veya "
              f"udev_rule.rules'i kur.")
        raise
    return fd


# ----------------------------------------------------------------------
# Temel protokol islemleri (FEATURE report ioctl — canitlanmis)
# ----------------------------------------------------------------------
def _write_feature(fd, buffer):
    """9 baytlik feature report'u karta yazar."""
    fcntl.ioctl(fd, HIDIOCSFEATURE_9, bytearray(buffer))
    time.sleep(0.04)


def _read_feature(fd):
    """Karttan 9 baytlik feature report okur (durum maskesi rep[8])."""
    rep = bytearray(REPORT_LEN)
    rep[0] = 0x00
    fcntl.ioctl(fd, HIDIOCGFEATURE_9, rep)
    return list(rep)


def read_state(fd):
    """8 rolenin durum maskesini okur (bit N = role N+1)."""
    try:
        rep = _read_feature(fd)
        return rep[8] if len(rep) >= 9 else 0
    except OSError:
        return None


def set_relay(fd, relay, on):
    """Tek roleyi ac/kapa. relay: 1..8, on: True/False"""
    cmd = CMD_ON if on else CMD_OFF
    buf = [0x00, cmd, relay, 0, 0, 0, 0, 0, 0]
    _write_feature(fd, buf)
    time.sleep(0.04)


def set_all(fd, on):
    """Tum roleyi ayni anda ac/kapa."""
    cmd = CMD_ALL_ON if on else CMD_ALL_OFF
    buf = [0x00, cmd, 0, 0, 0, 0, 0, 0, 0]
    _write_feature(fd, buf)
    time.sleep(0.04)


def get_states(fd):
    """Karttan gercek durum listesi okur: [True/False]*8"""
    mask = read_state(fd)
    if mask is None:
        return None
    return [bool((mask >> i) & 1) for i in range(RELAY_COUNT)]


def state_str(mask):
    s = []
    for i in range(RELAY_COUNT):
        s.append("1" if (mask >> i) & 1 else "0")
    return "".join(s)


# ----------------------------------------------------------------------
# CLI modlar
# ----------------------------------------------------------------------
def cmd_status(dev):
    fd = open_dev(dev)
    try:
        mask = read_state(fd)
        if mask is None:
            print("[!] Durum okunamadi (feature report desteklenmiyor olabilir).")
            return
        print(f"Durum maskesi: 0x{mask:02x}  ->  {state_str(mask)}")
        for i in range(RELAY_COUNT):
            st = "ACIK " if (mask >> i) & 1 else "kapali"
            print(f"  Role {i+1}: {st}")
    finally:
        os.close(fd)


def cmd_set(dev, chans, on):
    fd = open_dev(dev)
    try:
        for c in chans:
            set_relay(fd, c, on)
            print(f"  Role {c}: {'ACIK' if on else 'KAPALI'}")
        mask = read_state(fd)
        if mask is not None:
            print(f"  Yeni durum: {state_str(mask)}")
    finally:
        os.close(fd)


def cmd_all(dev, on):
    fd = open_dev(dev)
    try:
        set_all(fd, on)
        print(f"  Tum roler: {'ACIK' if on else 'KAPALI'}")
    finally:
        os.close(fd)


def cmd_auto(dev, interval=1.0):
    """Otomatik sirali ac-kapa: hepsi ac -> hepsi kapali -> 1..8 tek tek."""
    fd = open_dev(dev)
    try:
        print("=== OTOMATIK SIRALI AC-KAPA TESTI ===")
        print("Kartin LED'lerine bakin.")
        set_all(fd, True);  time.sleep(interval); print("  hepsi ACIK")
        set_all(fd, False); time.sleep(interval); print("  hepsi KAPALI")
        for ch in range(1, RELAY_COUNT + 1):
            set_relay(fd, ch, True);  time.sleep(interval/2); print(f"  role {ch} ACIK")
            set_relay(fd, ch, False); time.sleep(interval/2)
        set_all(fd, False); time.sleep(0.3); print("  test tamam, hepsi kapali")
    finally:
        os.close(fd)


# ----------------------------------------------------------------------
# GUI (tkinter) — masaustu kisa yol icin
# ----------------------------------------------------------------------
def run_gui(dev):
    import tkinter as tk
    from tkinter import messagebox

    root = tk.Tk()
    root.title("USBRelay8 Kontrol  (dcttech USBRelay8)")
    # Genis pencere: 8 roleyi 4x2 ızgara olarak tam goster
    root.geometry("760x440")
    root.minsize(640, 380)
    root.resizable(True, True)

    fd = open_dev(dev)
    atexit.register(os.close, fd)

    # Durum karttan GERCEK okunur (feature report ioctl — canitlanmis)
    state = get_states(fd) or [False] * RELAY_COUNT
    busy = [False]  # otomatik test sirasinda butonlari kilit

    # durum satiri
    status_var = tk.StringVar(value="00000000")
    tk.Label(root, textvariable=status_var, font=("Consolas", 22, "bold"),
             fg="#0f0", bg="#0d1117", anchor="w", padx=16).pack(fill="x", pady=(14, 2))
    tk.Label(root, text="Bitler: soldan Role1 ... Role8   (1 = ACIK, 0 = KAPALI)", fg="#888",
             font=("TkDefaultFont", 9)).pack(anchor="w", padx=16)
    info_var = tk.StringVar(value="Hazir")
    tk.Label(root, textvariable=info_var, fg="#cfe", font=("TkDefaultFont", 10, "bold"),
             anchor="w", padx=16).pack(fill="x", pady=(4, 0))

    btn_frame = tk.Frame(root)
    btn_frame.pack(fill="both", expand=True, padx=16, pady=10)
    # 4 sutun, 2 satir — her sutun esit genislikte (pencere genisleyince butonlar da genisler)
    for c in range(4):
        btn_frame.columnconfigure(c, weight=1, uniform="col")
    for r in range(2):
        btn_frame.rowconfigure(r, weight=1, uniform="row")

    btns = []
    for i in range(RELAY_COUNT):
        def make(idx):
            def toggle():
                if busy[0]:
                    return
                state[idx] = not state[idx]
                try:
                    set_relay(fd, idx + 1, state[idx])
                    info_var.set(f"Role {idx+1} -> "
                                 + ("ACIK" if state[idx] else "KAPALI"))
                except OSError as e:
                    info_var.set(f"[!] Yazma hatasi: {e}")
                refresh()
            return toggle
        b = tk.Button(btn_frame, text=f"Role {i+1}",
                      font=("TkDefaultFont", 13, "bold"),
                      command=make(i), bd=2, relief="raised",
                      activebackground="#444", activeforeground="#fff")
        b.grid(row=i // 4, column=i % 4, padx=8, pady=8, sticky="nsew")
        btns.append(b)

    def refresh():
        # Karttan gercek durumu oku (feature report)
        real = get_states(fd)
        if real is not None:
            state[:] = real
        mask = sum((1 << i) if state[i] else 0 for i in range(RELAY_COUNT))
        status_var.set(state_str(mask))
        for i, b in enumerate(btns):
            if state[i]:
                b.config(bg="#1f8a2e", fg="#fff", relief="sunken")
            else:
                b.config(bg="#2b2f36", fg="#ddd", relief="raised")

    def all_on():
        if busy[0]:
            return
        for i in range(RELAY_COUNT):
            state[i] = True
        try:
            set_all(fd, True)
            info_var.set("Tum roler ACIK")
        except OSError as e:
            info_var.set(f"[!] Yazma hatasi: {e}")
        refresh()

    def all_off():
        if busy[0]:
            return
        for i in range(RELAY_COUNT):
            state[i] = False
        try:
            set_all(fd, False)
            info_var.set("Tum roler KAPALI")
        except OSError as e:
            info_var.set(f"[!] Yazma hatasi: {e}")
        refresh()

    def auto():
        if busy[0]:
            return
        busy[0] = True
        info_var.set("Otomatik test calisiyor... kart LED'lerine bakin")

        def worker():
            try:
                # hepsi ac
                for i in range(RELAY_COUNT):
                    state[i] = True
                set_all(fd, True)
                _ui(refresh)
                time.sleep(1.2)
                # hepsi kapali
                for i in range(RELAY_COUNT):
                    state[i] = False
                set_all(fd, False)
                _ui(refresh)
                time.sleep(1.2)
                # tek tek ac-kapa
                for ch in range(1, RELAY_COUNT + 1):
                    state[ch - 1] = True
                    set_relay(fd, ch, True)
                    _ui(refresh)
                    time.sleep(0.7)
                    state[ch - 1] = False
                    set_relay(fd, ch, False)
                    _ui(refresh)
                    time.sleep(0.4)
                for i in range(RELAY_COUNT):
                    state[i] = False
                set_all(fd, False)
                _ui(refresh)
            finally:
                busy[0] = False
                _ui(lambda: info_var.set("Test tamam — hepsi KAPALI"))

        import threading
        threading.Thread(target=worker, daemon=True).start()

    def _ui(fn):
        # tkinter widget'lar YALNIZCA ana thread'den guncellenmeli
        try:
            root.after(0, fn)
        except Exception:
            pass

    bar = tk.Frame(root); bar.pack(fill="x", padx=16, pady=(0, 14))
    tk.Button(bar, text="Tümü AÇ", command=all_on, bg="#1f8a2e", fg="#fff",
              font=("TkDefaultFont", 11, "bold"), bd=2, relief="raised").pack(side="left", padx=6)
    tk.Button(bar, text="Tümünü KAPAT", command=all_off, bg="#8a1f1f", fg="#fff",
              font=("TkDefaultFont", 11, "bold"), bd=2, relief="raised").pack(side="left", padx=6)
    tk.Button(bar, text="Otomatik Test", command=auto, bg="#1f3a8a", fg="#fff",
              font=("TkDefaultFont", 11, "bold"), bd=2, relief="raised").pack(side="right", padx=6)

    refresh()
    root.mainloop()


# ----------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="USBRelay8 (dcttech) surucusu")
    ap.add_argument("--dev", help="/dev/hidrawX zorla")
    ap.add_argument("action", nargs="?", default="status",
                    choices=["status", "on", "off", "allon", "alloff", "auto", "gui"])
    ap.add_argument("chans", nargs="*", help="on/off icin kanal numaralari (1-8)")
    a = ap.parse_args()

    dev = find_relay_dev(a.dev)
    if not dev:
        print("[!] USBRelay8 (16c0:05df) bulunamadi. Karti bagladindan emin ol.")
        sys.exit(1)
    print(f"Kart: {dev}")

    if a.action == "status":
        cmd_status(dev)
    elif a.action in ("on", "off"):
        chans = [int(c) for c in a.chans] if a.chans else list(range(1, RELAY_COUNT + 1))
        cmd_set(dev, chans, a.action == "on")
    elif a.action == "allon":
        cmd_all(dev, True)
    elif a.action == "alloff":
        cmd_all(dev, False)
    elif a.action == "auto":
        cmd_auto(dev)
    elif a.action == "gui":
        run_gui(dev)


if __name__ == "__main__":
    main()
