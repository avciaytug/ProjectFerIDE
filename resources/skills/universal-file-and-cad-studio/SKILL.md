---
name: universal-file-and-cad-studio
description: Word (.docx/.doc/.odt), Excel (.xlsx/.xls/.ods/.csv), PowerPoint (.pptx/.ppt/.odp), PDF (.pdf), Görsel/OCR (.png/.jpg/.webp/.tiff/.svg), Müzik/Ses (.mp3/.wav/.flac/.ogg/.m4a) ve AutoCAD (.dwg/.dxf) dosyalarını okuma, üretme, düzenleme, dönüştürme ve masaüstünde açma kılavuzu.
---

# Evrensel Dosya, Ofis, Medya ve AutoCAD Stüdyosu (FerIDE v5.3.4)

Kullanıcı herhangi bir Ofis belgesi, PDF, Görsel, Müzik/Ses kaydı veya AutoCAD (`.dwg` / `.dxf`) projesi üzerinde okuma, analiz, oluşturma, düzenleme veya dönüştürme istediğinde aşağıdaki yerleşik araçları doğrudan kullan:

## 1. Dosya Anlama ve Analiz (`read_document`)
- Word (`.docx`, `.doc`, `.odt`, `.rtf`), Excel (`.xlsx`, `.xls`, `.ods`, `.csv`), PowerPoint (`.pptx`, `.ppt`, `.odp`), PDF (`.pdf` + taranmış PDF Türkçe/İngilizce OCR), Görsel (`.png`, `.jpg`, `.webp`, `.tiff`, `.svg` + EXIF + OCR), Müzik/Ses (`.mp3`, `.wav`, `.flac`, `.ogg`, `.m4a` -> ID3 etiketleri, ses yüksekliği dB analizi ve konuşma transkripsiyonu) ve AutoCAD (`.dwg`, `.dxf` -> sürüm, birimler, tüm katmanlar, bloklar, metinler ve ölçüler) için:
  `read_document({"path": "/tam/yol/dosya.dwg"})`

## 2. Sıfırdan Üretme ve Düzenleme (`edit_media_or_document`)
- **Word (`.docx`)**:
  - Yeni belge: `{"category": "docx", "action": "create", "output_path": "rapor.docx", "title": "Proje Raporu", "sections": [{"heading": "Özet", "paragraphs": ["..."], "bullets": ["..."], "table": [["Kolon1", "Kolon2"], ["A", "B"]]}]}`
  - Metin değiştir: `{"category": "docx", "action": "replace_text", "input_path": "eski.docx", "output_path": "yeni.docx", "replacements": {"2025": "2026"}}`
- **Excel (`.xlsx` / `.csv`)**:
  - Tablo üret: `{"category": "xlsx", "action": "create", "output_path": "maliyet.xlsx", "headers": ["Kalem", "Tutar"], "rows": [["Sunucu", 12000], ["Lisans", 4500]], "cells": {"B4": "=SUM(B2:B3)"}}`
  - Hücre güncelle: `{"category": "xlsx", "action": "update_cells", "input_path": "maliyet.xlsx", "output_path": "maliyet.xlsx", "cells": {"B2": 15000}}`
- **PowerPoint (`.pptx`)**:
  - Sunum üret: `{"category": "pptx", "action": "create", "output_path": "sunum.pptx", "slides": [{"title": "Mimari Sunum", "subtitle": "FerIDE v5.3.4"}, {"title": "Hedefler", "bullets": ["Otonom Kurulum", "AutoCAD Desteği"]}]}`
- **PDF (`.pdf`)**:
  - Türkçe UTF-8 PDF üret: `{"category": "pdf", "action": "create", "output_path": "belge.pdf", "title": "Teknik Şartname", "sections": [{"heading": "1. Kapsam", "paragraphs": ["..."]}]}`
  - Birleştir / Böl / Döndür / Damgala: `action: "merge"` (`input_paths`), `"extract_pages"`, `"rotate"`, `"stamp_text"`.
- **AutoCAD (`.dwg` ve `.dxf`)**:
  - Kat planı / teknik çizim üret veya mevcut `.dwg`/`.dxf` düzenle (ya da `.png`/`.svg`/`.pdf` olarak dışa aktar):
    `{"category": "cad", "action": "create", "output_path": "kat_plani.dwg", "units": "cm", "operations": [{"op": "add_rect", "layer": "DUVAR", "origin": [0, 0], "width": 600, "height": 450, "label": "SALON 27m2"}, {"op": "add_circle", "layer": "KOLON", "center": [300, 225], "radius": 25}, {"op": "add_text", "layer": "NOTLAR", "text": "ÖLÇEK 1/50", "pos": [20, -30], "height": 14}]}`
- **Görsel (`.png`, `.jpg`, `.webp`)**:
  - Yeniden boyutlandır, kırp, döndür, metin ekle veya format dönüştür:
    `{"category": "image", "input_path": "girdi.png", "output_path": "cikti.webp", "width": 1280, "rotate": 0, "annotate_text": "FerIDE"}`
- **Müzik ve Ses (`.mp3`, `.wav`, `.flac`, `.ogg`)**:
  - Kırp, birleştir, ses seviyesi/hız ayarla, normalize et veya ID3 etiketi yaz:
    `{"category": "audio", "action": "trim", "input_path": "kayit.mp3", "output_path": "kesit.mp3", "start_sec": 5, "end_sec": 45, "normalize": true, "title": "Bölüm 1"}`

## 3. Masaüstünde Açma (`open_file_in_system`)
- Üretilen veya düzenlenen dosyayı kullanıcının ekranında göstermek istendiğinde:
  `open_file_in_system({"path": "/tam/yol/kat_plani.dwg"})`

