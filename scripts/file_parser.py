#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE Universal File, CAD, Media & Document Parser (v5.3.6)
============================================================
Reads, analyzes, and extracts structured content + visual previews from:
- AutoCAD & CAD (.dwg, .dxf) via LibreDWG (dwg2dxf/dwgread) + ezdxf + Matplotlib PNG preview
- Microsoft Word & OpenDocument (.docx, .doc, .odt, .rtf)
- Microsoft Excel & Spreadsheets (.xlsx, .xls, .ods, .csv, .tsv)
- Microsoft PowerPoint & Presentations (.pptx, .ppt, .odp)
- PDF (.pdf) via PyMuPDF + pdfplumber + Scanned PDF Turkish/English OCR
- Images (.png, .jpg, .jpeg, .webp, .bmp, .gif, .tiff, .svg) via Pillow + EXIF + Tesseract OCR
- Audio & Music (.mp3, .wav, .flac, .ogg, .m4a, .aac, .opus, .wma) via Mutagen + ffprobe + STT
- Archives (.zip, .tar, .tar.gz, .tar.xz)
- Plain Text & Source Code
"""

import csv
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

HOME_DIR = os.path.expanduser("~")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
APP_ROOT = os.environ.get("FERIDE_ROOT") or os.path.dirname(SCRIPT_DIR)
FERIDE_DATA = os.path.join(HOME_DIR, ".feride")
PREVIEW_CACHE_DIR = os.path.join(FERIDE_DATA, "cache", "previews")

# Dinamik TESSDATA_PREFIX tespiti (sabit kullanıcı adı içermez)
for _tess_cand in [
    os.path.join(FERIDE_DATA, "tessdata"),
    os.path.join(HOME_DIR, ".local", "share", "tessdata"),
    "/usr/share/tesseract-ocr/5/tessdata",
    "/usr/share/tesseract-ocr/4.00/tessdata",
    "/usr/share/tessdata",
]:
    if os.path.isdir(_tess_cand) and "TESSDATA_PREFIX" not in os.environ:
        os.environ["TESSDATA_PREFIX"] = _tess_cand
        break


def format_size(bytes_val):
    if bytes_val < 1024:
        return f"{bytes_val} B"
    if bytes_val < 1024 * 1024:
        return f"{bytes_val / 1024:.1f} KB"
    if bytes_val < 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024):.1f} MB"
    return f"{bytes_val / (1024 * 1024 * 1024):.2f} GB"


def find_binary(name):
    candidates = [
        os.path.join(APP_ROOT, "bin", "cad", name),
        os.path.join(APP_ROOT, "bin", name),
        os.path.join(FERIDE_DATA, "bin", "cad", name),
        os.path.join(FERIDE_DATA, "bin", name),
        shutil.which(name),
    ]
    for c in candidates:
        if c and os.path.isfile(c):
            try:
                if not os.access(c, os.X_OK):
                    os.chmod(c, 0o755)
            except Exception:
                pass
            return c
    return None


def ensure_preview_dir():
    os.makedirs(PREVIEW_CACHE_DIR, exist_ok=True)
    return PREVIEW_CACHE_DIR


# ---------------------------------------------------------------------------
# 1. GÖRSEL & SVG ANALİZİ + OCR
# ---------------------------------------------------------------------------
def parse_image(file_path):
    file_name = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)
    ext = os.path.splitext(file_path)[1].lower()

    if ext == ".svg":
        return parse_svg(file_path)

    dimensions_str = "Bilinmiyor"
    fmt_str = "Bilinmiyor"
    mode_str = ""
    exif_lines = []
    rendered_png = None

    try:
        from PIL import ExifTags, Image

        with Image.open(file_path) as img:
            w, h = img.size
            dimensions_str = f"{w} x {h} piksel"
            fmt_str = img.format or ext.upper().lstrip(".")
            mode_str = f"({img.mode})"

            try:
                raw_exif = img.getexif()
                if raw_exif:
                    interesting = {"Make", "Model", "DateTime", "Software", "Artist", "Copyright"}
                    for tag_id, val in raw_exif.items():
                        tag_name = ExifTags.TAGS.get(tag_id, str(tag_id))
                        if tag_name in interesting and val:
                            exif_lines.append(f"  - {tag_name}: {val}")
            except Exception:
                pass

            # TIFF/BMP gibi formatları Vision LLM'in doğrudan görebilmesi için PNG önizlemeye çevir
            if ext in [".tiff", ".tif", ".bmp", ".ico"]:
                out_png = os.path.join(
                    ensure_preview_dir(),
                    f"img_{os.path.splitext(file_name)[0]}_{os.getpid()}.png",
                )
                rgb = img.convert("RGBA" if "A" in img.mode else "RGB")
                rgb.thumbnail((1568, 1568))
                rgb.save(out_png, "PNG")
                rendered_png = out_png
    except Exception:
        pass

    ocr_text = _run_ocr(file_path)

    output_lines = [
        f"### Görsel Detayı: {file_name}",
        f"- Çözünürlük: {dimensions_str} {mode_str}".strip(),
        f"- Format: {fmt_str}",
        f"- Dosya Boyutu: {format_size(file_size)}",
    ]
    if exif_lines:
        output_lines.append("- EXIF Meta Verileri:\n" + "\n".join(exif_lines))
    if ocr_text:
        output_lines.append("\n[Görselden Okunan Metinler (OCR)]:\n" + ocr_text)
    else:
        output_lines.append(
            "\n[Görselde okunabilir metin saptanamadı veya görsel çizim/fotoğraf ağırlıklı.]"
        )

    res = {
        "success": True,
        "file_type": "image",
        "dimensions": dimensions_str,
        "ocr_text": ocr_text,
        "content": "\n".join(output_lines),
    }
    if rendered_png:
        res["rendered_image"] = rendered_png
    return res


def parse_svg(file_path):
    file_name = os.path.basename(file_path)
    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
        width = root.attrib.get("width", "auto")
        height = root.attrib.get("height", "auto")
        viewbox = root.attrib.get("viewBox", "yok")
        texts = []
        elem_counts = {}
        for el in root.iter():
            tag = el.tag.split("}")[-1]
            elem_counts[tag] = elem_counts.get(tag, 0) + 1
            if el.text and el.text.strip():
                texts.append(el.text.strip())
        summary = [
            f"### Vektörel Görsel (SVG): {file_name}",
            f"- Boyutlar: width={width}, height={height}, viewBox={viewbox}",
            "- Eleman Özeti: " + ", ".join(f"{k}: {v}" for k, v in list(elem_counts.items())[:15]),
        ]
        if texts:
            summary.append("\n[SVG İçindeki Metinler]:\n" + "\n".join(texts[:100]))
        return {"success": True, "file_type": "svg", "content": "\n".join(summary)}
    except Exception as e:
        return parse_text(file_path)


def _run_ocr(image_path):
    try:
        import pytesseract
        from PIL import Image

        with Image.open(image_path) as img:
            for lang in ["tur+eng", "tur", "eng"]:
                try:
                    t = pytesseract.image_to_string(img, lang=lang).strip()
                    if t:
                        return t
                except Exception:
                    continue
    except Exception:
        pass

    for lang in ["tur+eng", "tur", "eng"]:
        try:
            proc = subprocess.run(
                ["tesseract", image_path, "stdout", "-l", lang],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                return proc.stdout.strip()
        except Exception:
            continue
    return ""


# ---------------------------------------------------------------------------
# 2. AUTOCAD (.DWG & .DXF) ANALİZİ + GÖRSEL ÖNİZLEME ÜRETİMİ
# ---------------------------------------------------------------------------
def parse_cad(file_path):
    file_name = os.path.basename(file_path)
    ext = os.path.splitext(file_path)[1].lower()
    temp_dxf = None
    rendered_png = None
    dxf_target = file_path

    try:
        if ext == ".dwg":
            dwg2dxf_bin = find_binary("dwg2dxf")
            if dwg2dxf_bin:
                fd, temp_dxf = tempfile.mkstemp(suffix=".dxf", prefix="feride_dwg_")
                os.close(fd)
                os.unlink(temp_dxf)
                subprocess.run(
                    [dwg2dxf_bin, "-y", "-o", temp_dxf, file_path],
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                if os.path.isfile(temp_dxf) and os.path.getsize(temp_dxf) > 32:
                    dxf_target = temp_dxf
                else:
                    return _parse_dwg_via_dwgread(file_path)
            else:
                return _parse_dwg_via_dwgread(file_path)

        import ezdxf

        doc = ezdxf.readfile(dxf_target)
        msp = doc.modelspace()

        dxf_ver = doc.dxfversion
        units_code = doc.header.get("$INSUNITS", 0)
        units_map = {
            0: "Belirtilmemiş (Birim)",
            1: "İnç (Inches)",
            2: "Fit (Feet)",
            4: "Milimetre (mm)",
            5: "Santimetre (cm)",
            6: "Metre (m)",
            7: "Kilometre (km)",
        }
        units_str = units_map.get(units_code, f"Kod {units_code}")

        layers_info = []
        for layer in doc.layers:
            lname = layer.dxf.name
            lcolor = getattr(layer.dxf, "color", "auto")
            state = "Kapalı" if layer.is_off() else ("Dondurulmuş" if layer.is_frozen() else "Açık")
            layers_info.append(f"  - `{lname}` (Renk: {lcolor}, Durum: {state})")

        entity_counts = {}
        layer_entity_counts = {}
        texts_found = []
        dimensions_found = []
        block_inserts = {}

        for ent in msp:
            etype = ent.dxftype()
            entity_counts[etype] = entity_counts.get(etype, 0) + 1
            elayer = getattr(ent.dxf, "layer", "0")
            layer_entity_counts[elayer] = layer_entity_counts.get(elayer, 0) + 1

            if etype == "TEXT":
                txt = getattr(ent.dxf, "text", "").strip()
                if txt:
                    pos = getattr(ent.dxf, "insert", None)
                    coord = f" ({pos.x:.1f}, {pos.y:.1f})" if pos is not None else ""
                    texts_found.append(f"  - [{elayer}]{coord}: {txt}")
            elif etype == "MTEXT":
                try:
                    txt = ent.plain_text().strip().replace("\n", " ")
                except Exception:
                    txt = getattr(ent.dxf, "text", "").strip()
                if txt:
                    texts_found.append(f"  - [{elayer}]: {txt}")
            elif etype == "DIMENSION":
                meas = getattr(ent.dxf, "actual_measurement", None)
                override = getattr(ent.dxf, "text", "")
                if meas is not None:
                    dimensions_found.append(f"  - [{elayer}] Ölçü: {meas:.2f} {override}".strip())
            elif etype == "INSERT":
                bname = getattr(ent.dxf, "name", "Block")
                block_inserts[bname] = block_inserts.get(bname, 0) + 1

        # Bounding box hesapla
        bbox_str = "Hesaplanamadı"
        try:
            from ezdxf import bbox as ez_bbox

            extents = ez_bbox.extents(msp, fast=True)
            if extents.has_data:
                w = extents.size.x
                h = extents.size.y
                z = extents.size.z
                bbox_str = (
                    f"Min({extents.extmin.x:.2f}, {extents.extmin.y:.2f}) -> "
                    f"Max({extents.extmax.x:.2f}, {extents.extmax.y:.2f}) | "
                    f"Genişlik: {w:.2f}, Yükseklik: {h:.2f}"
                    + (f", Derinlik(Z): {z:.2f}" if abs(z) > 1e-4 else "")
                )
        except Exception:
            pass

        # Görsel PNG önizleme üret (Vision mmproj için)
        try:
            import matplotlib

            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            from ezdxf.addons.drawing import Frontend, RenderContext
            from ezdxf.addons.drawing.matplotlib import MatplotlibBackend

            fig = plt.figure(figsize=(10, 7.5), dpi=160)
            ax = fig.add_axes([0, 0, 1, 1])
            ctx = RenderContext(doc)
            out_backend = MatplotlibBackend(ax)
            Frontend(ctx, out_backend).draw_layout(msp, finalize=True)
            out_png = os.path.join(
                ensure_preview_dir(),
                f"cad_{os.path.splitext(file_name)[0]}_{os.getpid()}.png",
            )
            fig.savefig(out_png, dpi=160, bbox_inches="tight", facecolor="#181824")
            plt.close(fig)
            if os.path.isfile(out_png) and os.path.getsize(out_png) > 100:
                rendered_png = out_png
        except Exception:
            pass

        lines = [
            f"### AutoCAD Teknik Çizim Analizi: {file_name}",
            f"- Dosya Türü: {ext.upper()} (DXF Çekirdek Sürümü: {dxf_ver})",
            f"- Çizim Birimi: {units_str}",
            f"- Sınır Kutusu (Bounding Box): {bbox_str}",
            f"- Toplam Modelspace Nesnesi: {sum(entity_counts.values())}",
        ]

        if entity_counts:
            lines.append(
                "\n#### Nesne Dağılımı (Entities)\n"
                + ", ".join(f"`{k}`: {v}" for k, v in sorted(entity_counts.items(), key=lambda x: -x[1]))
            )

        if layers_info:
            lines.append(f"\n#### Katmanlar (Layers — Toplam {len(layers_info)})")
            lines.extend(layers_info[:40])
            if len(layers_info) > 40:
                lines.append(f"  ... (+{len(layers_info) - 40} katman daha)")

        if block_inserts:
            lines.append("\n#### Kullanılan Bloklar (INSERT)")
            for bk, cnt in sorted(block_inserts.items(), key=lambda x: -x[1])[:25]:
                lines.append(f"  - `{bk}`: {cnt} adet")

        if dimensions_found:
            lines.append(f"\n#### Ölçülendirmeler (Dimensions — {len(dimensions_found)} adet)")
            lines.extend(dimensions_found[:40])

        if texts_found:
            lines.append(f"\n#### Çizim Üzerindeki Yazılar ve Etiketler ({len(texts_found)} adet)")
            lines.extend(texts_found[:80])
            if len(texts_found) > 80:
                lines.append(f"  ... (+{len(texts_found) - 80} metin daha)")

        if rendered_png:
            lines.append(f"\n[CAD Görsel Önizleme Üretildi: {rendered_png}]")

        res = {
            "success": True,
            "file_type": "cad",
            "cad_format": ext.lstrip("."),
            "layer_count": len(layers_info),
            "entity_count": sum(entity_counts.values()),
            "content": "\n".join(lines),
        }
        if rendered_png:
            res["rendered_image"] = rendered_png
        return res
    except Exception as e:
        return {"success": False, "error": f"CAD çizimi ({file_name}) ayrıştırılamadı: {e}"}
    finally:
        if temp_dxf and os.path.exists(temp_dxf):
            try:
                os.unlink(temp_dxf)
            except Exception:
                pass


def _parse_dwg_via_dwgread(file_path):
    dwglayers_bin = find_binary("dwglayers")
    dwgread_bin = find_binary("dwgread")
    layers = []
    if dwglayers_bin:
        try:
            p = subprocess.run([dwglayers_bin, file_path], capture_output=True, text=True, timeout=30)
            if p.returncode == 0:
                layers = [l.strip() for l in p.stdout.splitlines() if l.strip()]
        except Exception:
            pass

    if dwgread_bin:
        try:
            p = subprocess.run([dwgread_bin, "-O", "JSON", file_path], capture_output=True, text=True, timeout=45)
            raw_json = p.stdout
            if raw_json and "OBJECTS" in raw_json:
                return {
                    "success": True,
                    "file_type": "cad",
                    "content": (
                        f"### AutoCAD DWG Dosyası: {os.path.basename(file_path)}\n"
                        f"- Katmanlar ({len(layers)}): {', '.join(layers[:30]) if layers else 'Belirtilmemiş'}\n"
                        f"- Ham DWG Yapı Özeti (ilk 4000 krk):\n{raw_json[:4000]}"
                    ),
                }
        except Exception:
            pass

    return {
        "success": False,
        "error": "DWG dönüştürücü (dwg2dxf / LibreDWG) bulunamadı veya dosya sürümü okunamadı.",
    }


# ---------------------------------------------------------------------------
# 3. PDF ANALİZİ + TABLO + TARANMIŞ BELGE OCR
# ---------------------------------------------------------------------------
def parse_pdf(file_path):
    text_parts = []
    page_count = 0
    rendered_png = None

    try:
        import pymupdf as fitz

        doc = fitz.open(file_path)
        page_count = len(doc)
        meta = doc.metadata or {}
        header = [f"### PDF Belgesi: {os.path.basename(file_path)} ({page_count} Sayfa)"]
        if meta.get("title"):
            header.append(f"- Başlık: {meta['title']}")
        if meta.get("author"):
            header.append(f"- Yazar: {meta['author']}")
        text_parts.append("\n".join(header))

        for page_num in range(min(page_count, 80)):
            page = doc[page_num]
            text = page.get_text().strip()
            if text:
                text_parts.append(f"--- Sayfa {page_num + 1} ---\n{text}")
        doc.close()
    except Exception:
        pass

    if len(text_parts) <= 1:
        try:
            proc = subprocess.run(
                ["pdftotext", "-layout", file_path, "-"],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                text_parts.append(proc.stdout.strip())
        except Exception:
            pass

    if len(text_parts) <= 1:
        try:
            from pypdf import PdfReader

            reader = PdfReader(file_path)
            page_count = len(reader.pages)
            for idx, page in enumerate(reader.pages[:80]):
                t = (page.extract_text() or "").strip()
                if t:
                    text_parts.append(f"--- Sayfa {idx + 1} ---\n{t}")
        except Exception:
            pass

    content = "\n\n".join(text_parts).strip()
    body_only = "\n".join(text_parts[1:]).strip() if len(text_parts) > 1 else ""

    # Taranmış (salt resim) PDF ise ilk sayfaları PNG'ye çevir + OCR uygula
    if len(body_only) < 40:
        try:
            import pymupdf as fitz

            doc = fitz.open(file_path)
            page_count = len(doc)
            ocr_pages = []
            for p_idx in range(min(page_count, 12)):
                pix = doc[p_idx].get_pixmap(dpi=160)
                page_png = os.path.join(
                    ensure_preview_dir(),
                    f"pdf_p{p_idx + 1}_{os.getpid()}.png",
                )
                pix.save(page_png)
                if p_idx == 0:
                    rendered_png = page_png
                p_text = _run_ocr(page_png)
                if p_idx > 0:
                    try:
                        os.unlink(page_png)
                    except Exception:
                        pass
                if p_text:
                    ocr_pages.append(f"--- Sayfa {p_idx + 1} (OCR) ---\n{p_text}")
            doc.close()
            if ocr_pages:
                content = (
                    f"### Taranmış PDF Belgesi: {os.path.basename(file_path)} ({page_count} Sayfa)\n\n"
                    + "\n\n".join(ocr_pages)
                )
        except Exception:
            pass

    if not content:
        content = "[PDF içeriğinde seçilebilir metin bulunamadı.]"

    res = {
        "success": True,
        "file_type": "pdf",
        "page_count": page_count,
        "content": content,
    }
    if rendered_png:
        res["rendered_image"] = rendered_png
    return res


# ---------------------------------------------------------------------------
# 4. OFİS DOSYALARI (WORD, EXCEL, POWERPOINT, OPENDOCUMENT, CSV)
# ---------------------------------------------------------------------------
def _libreoffice_convert_to_text_or_modern(file_path, target_ext):
    soffice = shutil.which("libreoffice") or shutil.which("soffice")
    if not soffice:
        return None
    tmp_dir = tempfile.mkdtemp(prefix="feride_lo_")
    try:
        subprocess.run(
            [soffice, "--headless", "--convert-to", target_ext, "--outdir", tmp_dir, file_path],
            capture_output=True,
            timeout=45,
        )
        for name in os.listdir(tmp_dir):
            if name.lower().endswith(f".{target_ext}"):
                return os.path.join(tmp_dir, name), tmp_dir
    except Exception:
        pass
    shutil.rmtree(tmp_dir, ignore_errors=True)
    return None


def parse_docx(file_path):
    ext = os.path.splitext(file_path)[1].lower()
    cleanup_dir = None
    actual_path = file_path

    if ext in [".doc", ".odt", ".rtf"]:
        conv = _libreoffice_convert_to_text_or_modern(file_path, "docx")
        if conv:
            actual_path, cleanup_dir = conv
        elif ext == ".odt":
            try:
                with zipfile.ZipFile(file_path, "r") as z:
                    xml_tree = ET.fromstring(z.read("content.xml"))
                    texts = [t.strip() for t in xml_tree.itertext() if t and t.strip()]
                    return {"success": True, "file_type": "odt", "content": "\n".join(texts)}
            except Exception as e:
                return {"success": False, "error": f"ODT okunamadı: {e}"}

    try:
        try:
            from docx import Document

            doc = Document(actual_path)
            paragraphs = []
            for p_obj in doc.paragraphs:
                t = p_obj.text.strip()
                if t:
                    if p_obj.style and p_obj.style.name.startswith("Heading"):
                        paragraphs.append(f"\n### {t}\n")
                    else:
                        paragraphs.append(t)

            for table_idx, table in enumerate(doc.tables):
                paragraphs.append(f"\n#### Tablo {table_idx + 1}")
                for r_idx, row in enumerate(table.rows):
                    cells = [c.text.strip().replace("\n", " ") for c in row.cells]
                    paragraphs.append("| " + " | ".join(cells) + " |")
                    if r_idx == 0:
                        paragraphs.append("| " + " | ".join(["---"] * len(cells)) + " |")

            content = "\n".join(paragraphs).strip()
            return {
                "success": True,
                "file_type": "docx",
                "paragraph_count": len(doc.paragraphs),
                "table_count": len(doc.tables),
                "content": content or "[Word belgesi boş görünüyor.]",
            }
        except Exception:
            pass

        with zipfile.ZipFile(actual_path, "r") as z:
            xml_content = z.read("word/document.xml")
            tree = ET.fromstring(xml_content)
            paragraphs = []
            for p_elem in tree.iter("{http://schemas.openxmlformats.org/wordprocessingml/2006/main}p"):
                texts = [
                    t.text
                    for t in p_elem.iter("{http://schemas.openxmlformats.org/wordprocessingml/2006/main}t")
                    if t.text
                ]
                line = "".join(texts).strip()
                if line:
                    paragraphs.append(line)
            return {
                "success": True,
                "file_type": "docx",
                "content": "\n".join(paragraphs) if paragraphs else "[Belge boş.]",
            }
    except Exception as e:
        return {"success": False, "error": f"Word belgesi açılamadı: {e}"}
    finally:
        if cleanup_dir:
            shutil.rmtree(cleanup_dir, ignore_errors=True)


def parse_excel(file_path):
    ext = os.path.splitext(file_path)[1].lower()

    if ext == ".xls":
        try:
            import xlrd

            wb = xlrd.open_workbook(file_path)
            sheets_out = []
            for s in wb.sheets():
                sheets_out.append(f"### Sayfa: {s.name} ({s.nrows} satır x {s.ncols} sütun)")
                for r in range(min(s.nrows, 200)):
                    vals = [str(s.cell_value(r, c)) for c in range(s.ncols)]
                    sheets_out.append("| " + " | ".join(vals) + " |")
                    if r == 0 and s.ncols > 0:
                        sheets_out.append("| " + " | ".join(["---"] * s.ncols) + " |")
            return {"success": True, "file_type": "xls", "content": "\n".join(sheets_out)}
        except Exception:
            pass

    if ext == ".ods":
        conv = _libreoffice_convert_to_text_or_modern(file_path, "xlsx")
        if conv:
            res = parse_excel(conv[0])
            shutil.rmtree(conv[1], ignore_errors=True)
            return res

    try:
        import openpyxl

        wb = openpyxl.load_workbook(file_path, data_only=True, read_only=True)
        sheet_texts = []
        for sheet_name in wb.sheetnames:
            sheet = wb[sheet_name]
            sheet_texts.append(f"### Sayfa: {sheet_name}")
            rows_data = []
            max_rows = 250
            header_done = False

            for idx, row in enumerate(sheet.iter_rows(values_only=True)):
                if idx >= max_rows:
                    rows_data.append(f"... (İlk {max_rows} satır gösterildi) ...")
                    break
                if all(v is None for v in row):
                    continue
                row_str = [str(v).replace("\n", " ") if v is not None else "" for v in row]
                rows_data.append("| " + " | ".join(row_str) + " |")
                if not header_done and row_str:
                    rows_data.append("| " + " | ".join(["---"] * len(row_str)) + " |")
                    header_done = True

            sheet_texts.append("\n".join(rows_data) if rows_data else "[Sayfa boş]")
        wb.close()
        return {
            "success": True,
            "file_type": "xlsx",
            "sheet_count": len(wb.sheetnames),
            "content": "\n\n".join(sheet_texts),
        }
    except Exception as e:
        return {"success": False, "error": f"Excel dosyası okunamadı: {e}"}


def parse_csv(file_path):
    try:
        rows_data = []
        max_rows = 250
        for enc in ["utf-8", "utf-8-sig", "cp1254", "iso-8859-9", "latin-1"]:
            try:
                with open(file_path, "r", encoding=enc) as f:
                    sample = f.read(4096)
                    f.seek(0)
                    dialect = None
                    try:
                        dialect = csv.Sniffer().sniff(sample)
                    except Exception:
                        pass
                    reader = csv.reader(f, dialect=dialect) if dialect else csv.reader(f)
                    for idx, row in enumerate(reader):
                        if idx >= max_rows:
                            rows_data.append(f"... (İlk {max_rows} satır gösterildi) ...")
                            break
                        rows_data.append("| " + " | ".join(row) + " |")
                        if idx == 0 and row:
                            rows_data.append("| " + " | ".join(["---"] * len(row)) + " |")
                break
            except UnicodeDecodeError:
                continue
        return {
            "success": True,
            "file_type": "csv",
            "content": "\n".join(rows_data) if rows_data else "[CSV dosyası boş]",
        }
    except Exception as e:
        return {"success": False, "error": f"CSV okunamadı: {e}"}


def parse_pptx(file_path):
    ext = os.path.splitext(file_path)[1].lower()
    cleanup_dir = None
    actual_path = file_path

    if ext in [".ppt", ".odp"]:
        conv = _libreoffice_convert_to_text_or_modern(file_path, "pptx")
        if conv:
            actual_path, cleanup_dir = conv

    try:
        from pptx import Presentation

        prs = Presentation(actual_path)
        slides_text = []
        for idx, slide in enumerate(prs.slides):
            slide_content = []
            for shape in slide.shapes:
                if getattr(shape, "has_text_frame", False) and shape.text.strip():
                    slide_content.append(shape.text.strip())
                elif getattr(shape, "has_table", False):
                    for row in shape.table.rows:
                        cells = [c.text.strip().replace("\n", " ") for c in row.cells]
                        slide_content.append("| " + " | ".join(cells) + " |")
            if slide.has_notes_slide and slide.notes_slide.notes_text_frame:
                note = slide.notes_slide.notes_text_frame.text.strip()
                if note:
                    slide_content.append(f"[Konuşmacı Notu]: {note}")
            slides_text.append(
                f"--- Slayt {idx + 1} ---\n"
                + ("\n".join(slide_content) if slide_content else "[Görsel / Metin yok]")
            )
        return {
            "success": True,
            "file_type": "pptx",
            "slide_count": len(prs.slides),
            "content": "\n\n".join(slides_text),
        }
    except Exception as e:
        return {"success": False, "error": f"Sunum okunamadı: {e}"}
    finally:
        if cleanup_dir:
            shutil.rmtree(cleanup_dir, ignore_errors=True)


# ---------------------------------------------------------------------------
# 5. SES & MÜZİK DOSYALARI (ID3 ETİKET + TEKNİK ANALİZ + STT DEŞİFRE)
# ---------------------------------------------------------------------------
def parse_audio(file_path):
    file_name = os.path.basename(file_path)
    info_lines = [f"### Ses / Müzik Dosyası Analizi: {file_name}"]

    # 1. Mutagen ile ID3 / FLAC / MP4 / OGG etiketleri ve teknik bilgiler
    try:
        import mutagen

        m_file = mutagen.File(file_path, easy=True)
        if m_file is not None:
            if getattr(m_file, "info", None):
                inf = m_file.info
                dur = getattr(inf, "length", 0)
                mins, secs = int(dur // 60), dur % 60
                info_lines.append(f"- Süre: {mins} dk {secs:.1f} sn ({dur:.1f} saniye)")
                sr = getattr(inf, "sample_rate", None)
                ch = getattr(inf, "channels", None)
                br = getattr(inf, "bitrate", None)
                tech = []
                if sr:
                    tech.append(f"{sr} Hz")
                if ch:
                    tech.append("Stereo" if ch == 2 else (f"{ch} Kanal" if ch != 1 else "Mono"))
                if br:
                    tech.append(f"{int(br / 1000)} kbps")
                if tech:
                    info_lines.append(f"- Ses Formatı: {' • '.join(tech)}")
            if m_file.tags:
                tag_lines = []
                for key in ["title", "artist", "album", "genre", "date", "bpm"]:
                    if key in m_file.tags and m_file.tags[key]:
                        val = ", ".join(str(x) for x in m_file.tags[key])
                        tag_lines.append(f"  - {key.capitalize()}: {val}")
                if tag_lines:
                    info_lines.append("- Müzik / Medya Etiketleri:\n" + "\n".join(tag_lines))
    except Exception:
        pass

    # 2. ffprobe / ffmpeg ses seviyesi (dB) özeti
    if len(info_lines) == 1 and shutil.which("ffprobe"):
        try:
            pr = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "quiet",
                    "-print_format",
                    "json",
                    "-show_format",
                    "-show_streams",
                    file_path,
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if pr.returncode == 0:
                pdata = json.loads(pr.stdout)
                fmt = pdata.get("format", {})
                dur = float(fmt.get("duration", 0) or 0)
                info_lines.append(f"- Süre: {dur:.1f} sn | Format: {fmt.get('format_long_name', 'Ses')}")
        except Exception:
            pass

    if shutil.which("ffmpeg"):
        try:
            vp = subprocess.run(
                ["ffmpeg", "-i", file_path, "-af", "volumedetect", "-vn", "-sn", "-dn", "-f", "null", os.devnull],
                capture_output=True,
                text=True,
                timeout=20,
            )
            mean_v, max_v = None, None
            for line in vp.stderr.splitlines():
                if "mean_volume:" in line:
                    mean_v = line.split("mean_volume:")[-1].strip()
                elif "max_volume:" in line:
                    max_v = line.split("max_volume:")[-1].strip()
            if mean_v or max_v:
                info_lines.append(f"- Ses Seviyesi: Ortalama {mean_v or '?'}, Tepe (Peak) {max_v or '?'}")
        except Exception:
            pass

    # 3. Konuşma / Söz Deşifresi (Önce yerel port 5052 STT sunucusu, kapalıysa doğrudan faster-whisper + numpy PCM)
    transcription = ""
    try:
        with open(file_path, "rb") as f:
            audio_bytes = f.read()
        req = urllib.request.Request(
            "http://127.0.0.1:5052/transcribe",
            data=audio_bytes,
            headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": str(len(audio_bytes)),
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=45) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8"))
                transcription = data.get("text", "").strip()
    except Exception:
        pass

    if not transcription:
        try:
            import numpy as np
            from faster_whisper import WhisperModel

            ffmpeg_bin = shutil.which("ffmpeg")
            audio_f32 = None
            if ffmpeg_bin:
                proc = subprocess.run(
                    [
                        ffmpeg_bin,
                        "-nostdin",
                        "-threads",
                        "0",
                        "-i",
                        file_path,
                        "-f",
                        "s16le",
                        "-ac",
                        "1",
                        "-acodec",
                        "pcm_s16le",
                        "-ar",
                        "16000",
                        "-",
                    ],
                    capture_output=True,
                    timeout=45,
                )
                if proc.returncode == 0 and len(proc.stdout) > 0:
                    audio_f32 = np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0

            if audio_f32 is not None and len(audio_f32) > 1600:
                bundled_base = os.path.join(APP_ROOT, "models", "whisper", "base")
                cache_dir = os.path.join(FERIDE_DATA, "cache", "whisper")
                os.makedirs(cache_dir, exist_ok=True)
                if os.path.isfile(os.path.join(bundled_base, "model.bin")):
                    model = WhisperModel(bundled_base, device="cpu", compute_type="int8")
                else:
                    model = WhisperModel("base", device="cpu", compute_type="int8", download_root=cache_dir)
                segments, w_info = model.transcribe(audio_f32, beam_size=3)
                seg_texts = [seg.text.strip() for seg in segments if seg.text.strip()]
                if seg_texts:
                    transcription = f"(Dil: {w_info.language})\n" + " ".join(seg_texts)
        except Exception:
            pass

    if transcription:
        info_lines.append(f"\n#### Konuşma / Vokal Deşifresi (STT)\n{transcription}")
    else:
        info_lines.append(
            "\n[Not: Teknik ses/müzik meta verileri çıkarıldı. Enstrümantal parça olabilir veya konuşma saptanmadı.]"
        )

    return {
        "success": True,
        "file_type": "audio",
        "content": "\n".join(info_lines),
    }


# ---------------------------------------------------------------------------
# 6. ARŞİV & DÜZ METİN OKUMA
# ---------------------------------------------------------------------------
def parse_archive(file_path):
    file_name = os.path.basename(file_path)
    entries = []
    try:
        if zipfile.is_zipfile(file_path):
            with zipfile.ZipFile(file_path, "r") as z:
                for info in z.infolist()[:150]:
                    entries.append(f"  - `{info.filename}` ({format_size(info.file_size)})")
        elif tarfile.is_tarfile(file_path):
            with tarfile.open(file_path, "r:*") as tf:
                for idx, m in enumerate(tf):
                    if idx >= 150:
                        break
                    entries.append(f"  - `{m.name}` ({format_size(m.size)})")
        return {
            "success": True,
            "file_type": "archive",
            "content": f"### Arşiv İçeriği: {file_name}\n" + ("\n".join(entries) if entries else "[Boş arşiv]"),
        }
    except Exception as e:
        return {"success": False, "error": f"Arşiv okunamadı: {e}"}


def parse_text(file_path):
    for enc in ["utf-8", "utf-8-sig", "cp1254", "iso-8859-9", "latin-1"]:
        try:
            with open(file_path, "r", encoding=enc) as f:
                content = f.read()
            return {"success": True, "file_type": "text", "content": content}
        except UnicodeDecodeError:
            continue
    return {"success": False, "error": "Dosya ikili (binary) formatta veya kodlaması desteklenmiyor."}


def parse_file(file_path):
    if not os.path.exists(file_path):
        return {"success": False, "error": f"Dosya bulunamadı: {file_path}"}

    ext = os.path.splitext(file_path)[1].lower()
    file_name = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)

    if ext in [".dwg", ".dxf"]:
        res = parse_cad(file_path)
    elif ext in [".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".tiff", ".tif", ".svg", ".ico"]:
        res = parse_image(file_path)
    elif ext == ".pdf":
        res = parse_pdf(file_path)
    elif ext in [".docx", ".doc", ".odt", ".rtf"]:
        res = parse_docx(file_path)
    elif ext in [".xlsx", ".xls", ".ods"]:
        res = parse_excel(file_path)
    elif ext in [".csv", ".tsv"]:
        res = parse_csv(file_path)
    elif ext in [".pptx", ".ppt", ".odp"]:
        res = parse_pptx(file_path)
    elif ext in [".mp3", ".wav", ".m4a", ".ogg", ".flac", ".aac", ".opus", ".wma"]:
        res = parse_audio(file_path)
    elif ext in [".zip", ".tar", ".gz", ".tgz", ".xz"] and (
        zipfile.is_zipfile(file_path) or tarfile.is_tarfile(file_path)
    ):
        res = parse_archive(file_path)
    else:
        res = parse_text(file_path)

    res["file_name"] = file_name
    res["file_path"] = file_path
    res["file_size"] = file_size
    if "content" in res:
        res["char_count"] = len(res["content"])
    return res


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"success": False, "error": "Kullanım: file_parser.py <dosya_yolu>"}))
        sys.exit(1)

    result = parse_file(sys.argv[1])
    print(json.dumps(result, ensure_ascii=False))
