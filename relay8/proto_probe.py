#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Protokol keşif: farklı yazma formatlarını dener.
Kullanıcının kart LED'lerine bakarak hangi formatın röleyi
çektiğini söylemesi için. Her format 2 sn bekler."""
import os, time, sys, glob

def find():
    for h in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            dev=os.path.realpath(os.path.join(h,"device"))
        except OSError:
            continue
        if "16C0:05DF" in dev.upper():
            return "/dev/hidraw"+os.path.basename(h).replace("hidraw","")
    return None

dev=find()
print("DEV =",dev)
fd=os.open(dev, os.O_RDWR)

def w(data):
    os.write(fd, bytes(data))

def pause():
    print(">>> 2 sn bekleniyor, kart LED'lerine bakin...")
    time.sleep(2.0)

tests = [
    ("A: 9B id00 st01 relay01 (mevcut)", bytearray([0x00,0x01,0x01,0,0,0,0,0,0])),
    ("B: 9B id00 relay01 st01 (sira degisik)", bytearray([0x00,0x01,0x01,0,0,0,0,0,0])),
    ("C: 8B mask 0x01 (bit0=role1)", bytearray([0x01,0,0,0,0,0,0,0])),
    ("D: 9B id01 mask0x01", bytearray([0x01,0x01,0,0,0,0,0,0,0])),
    ("E: 8B mask 0xFF hepsi", bytearray([0xFF,0,0,0,0,0,0,0])),
    ("F: 1B mask 0x01", bytearray([0x01])),
    ("G: 9B id00 mask0x01", bytearray([0x00,0x01,0,0,0,0,0,0,0])),
]

for name, data in tests:
    print("TEST", name, "->", ' '.join(f'{b:02x}' for b in data))
    try:
        w(data)
    except OSError as e:
        print("  yazma hatasi:", e)
    pause()

os.close(fd)
print("Bitti. Hangi test numarasi roleyi cekti?")
