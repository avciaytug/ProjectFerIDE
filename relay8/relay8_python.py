#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
5V 8-Kanal USB Röle Kartı — Python Sürücüsü (PC <-> Arduino <-> Röle)

Bağlantı:
  PC (USB) -> Arduino Nano/Micro (COM port) -> Röle kartı IN1..IN8

Bu betik, Arduino tarafına (relay8_arduino.ino) seri port üzerinden
komut gönderir. Yani PC'den tek tıkla röle açma/kapatma yaparsın.

Kullanım:
    pip install pyserial
    python relay8_python.py                  # etkileşimli menü
    python relay8_python.py on 1             # 1. röleyi aç
    python relay8_python.py off 3            # 3. röleyi kapat
    python relay8_python.py toggle 4         # 4. röleyi ters çevir
    python relay8_python.py on 1 2 3         # 1,2,3'ü aç
    python relay8_python.py allon
    python relay8_python.py alloff
    python relay8_python.py status

COM portu:
    COMPORT ortam değişkeni veya arguman: COMPORT=COM5 python relay8_python.py status
    (Linux/Mac: /dev/ttyUSB0 veya /dev/ttyACM0)
"""

import sys
import os

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("pyserial kurulu degil. Kurma:  pip install pyserial")
    sys.exit(1)

BAUD = 9600


def pick_port() -> str:
    """COMPORT ortam degiskeni varsa onu, yoksa tek portu, yoksa liste."""
    env = os.environ.get("COMPORT")
    if env:
        return env
    ports = [p.device for p in serial.tools.list_ports.comports()]
    if len(ports) == 1:
        return ports[0]
    if not ports:
        print("COM portu bulunamadi. COMPORT=CAXX ortam degiskeni ayarla.")
        sys.exit(1)
    print("Bulunan portler:")
    for i, p in enumerate(ports, 1):
        print(f"  {i}) {p}")
    choice = input("Secim: ").strip()
    return ports[int(choice) - 1]


def open_serial(port: str) -> serial.Serial:
    return serial.Serial(port, BAUD, timeout=1)


def send_cmd(ser: serial.Serial, cmd: str) -> str:
    ser.reset_input_buffer()
    ser.write((cmd + "\n").encode())
    # Arduino yanitini bir miktar bekleyip oku
    import time
    time.sleep(0.15)
    data = ser.read(ser.in_waiting).decode(errors="ignore") if ser.in_waiting else ""
    return data


def cmd_on(ser, chans):
    for c in chans:
        send_cmd(ser, str(c))


def cmd_off(ser, chans):
    # Arduino tarafinda "0" = kapat (tek kanal).
    for c in chans:
        send_cmd(ser, "0")


def main():
    args = [a for a in sys.argv[1:]]
    port = pick_port()
    print(f"Port: {port}")
    ser = open_serial(port)

    if not args:
        interactive(ser)
        return

    action = args[0].lower()
    try:
        if action in ("on", "ac", "aç"):
            chans = [int(a) for a in args[1:]]
            cmd_on(ser, chans)
        elif action in ("off", "kapat", "kapat"):
            for a in args[1:]:
                send_cmd(ser, "0")
        elif action == "toggle":
            for a in args[1:]:
                send_cmd(ser, f"toggle {a}")
        elif action == "allon":
            send_cmd(ser, "allon")
        elif action == "alloff":
            send_cmd(ser, "alloff")
        elif action == "status":
            send_cmd(ser, "status")
        else:
            print("Bilinmeyen islem. Kullan: on/off/toggle/allon/alloff/status")
    finally:
        ser.close()


def interactive(ser: serial.Serial):
    print("Etkilesimli mod. 'q' ile cikis.")
    print("Komutlar: 1..8 (ac), k1..k8 (kapat), allon, alloff, status, toggle N")
    while True:
        try:
            c = input("röle> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            break
        if c in ("q", "quit", "exit", "çık"):
            break
        if c == "status":
            send_cmd(ser, "status")
        elif c == "allon":
            send_cmd(ser, "allon")
        elif c == "alloff":
            send_cmd(ser, "alloff")
        elif c.startswith("toggle"):
            send_cmd(ser, c)
        elif c.startswith("k"):  # kapat -> k1..k8
            try:
                n = int(c[1:])
                send_cmd(ser, "0")
            except ValueError:
                print("Format: k1..k8")
        elif c.isdigit():
            send_cmd(ser, c)
        else:
            print("Bilinmeyen komut.")
    ser.close()


if __name__ == "__main__":
    main()
