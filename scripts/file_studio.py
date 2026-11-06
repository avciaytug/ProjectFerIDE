#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE Universal File, Office, PDF, Image, Audio & AutoCAD Studio (v5.3.4)
==========================================================================
Creates, edits, converts, and exports:
- Word (.docx)
- Excel (.xlsx, .csv)
- PowerPoint (.pptx)
- PDF (.pdf) — full UTF-8 / Turkish character support via PyMuPDF Story
- AutoCAD (.dwg & .dxf) — via ezdxf + LibreDWG (dwg2dxf / dxf2dwg) + PNG/SVG/PDF export
- Images (.png, .jpg, .webp, .bmp, .tiff) — via Pillow
- Audio & Music (.mp3, .wav, .flac, .ogg, .m4a) — via ffmpeg & mutagen

Usage:
  python3 file_studio.py '<json_payload>'
  or stdin JSON when called with --stdin
"""

import csv
import html
import json
import os
import shutil
import subprocess
import sys
import tempfile

HOME_DIR = os.path.expanduser("~")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
APP_ROOT = os.environ.get("FERIDE_ROOT") or os.path.dirname(SCRIPT_DIR)
FERIDE_DATA = os.path.join(HOME_DIR, ".feride")


def find_binary(name):
    for c in [
        os.path.join(APP_ROOT, "bin", "cad", name),
        os.path.join(APP_ROOT, "bin", name),
        os.path.join(FERIDE_DATA, "bin", "cad", name),
        os.path.join(FERIDE_DATA, "bin", name),
        shutil.which(name),
    ]:
        if c and os.path.isfile(c):
            try:
                if not os.access(c, os.X_OK):
                    os.chmod(c, 0o755)
            except Exception:
                pass
            return c
    return None


def ensure_parent(path):
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)


# ---------------------------------------------------------------------------
# 1. WORD (.DOCX) OLUŞTURMA VE DÜZENLEME
# ---------------------------------------------------------------------------
def handle_docx(spec):
    from docx import Document

    action = spec.get("action", "create")
    input_path = spec.get("input_path")
    output_path = spec.get("output_path") or input_path
    if not output_path:
        return {"success": False, "error": "output_path zorunludur."}
    ensure_parent(output_path)

    doc = Document(input_path) if (input_path and os.path.isfile(input_path) and action != "create") else Document()

    if action == "replace_text":
        replacements = spec.get("replacements", {})
        if not replacements and spec.get("find"):
            replacements = {spec["find"]: spec.get("replace", "")}
        count = 0
        for p_obj in doc.paragraphs:
            for k, v in replacements.items():
                if k in p_obj.text:
                    p_obj.text = p_obj.text.replace(k, str(v))
                    count += 1
        for tbl in doc.tables:
            for row in tbl.rows:
                for cell in row.cells:
                    for k, v in replacements.items():
                        if k in cell.text:
                            cell.text = cell.text.replace(k, str(v))
                            count += 1
        doc.save(output_path)
        return {"success": True, "output_path": output_path, "message": f"Word belgesinde {count} değişiklik yapıldı."}

    title = spec.get("title")
    if title:
        doc.add_heading(str(title), level=0)

    for p_text in spec.get("paragraphs", []):
        doc.add_paragraph(str(p_text))

    for sec in spec.get("sections", []):
        if sec.get("heading"):
            doc.add_heading(str(sec["heading"]), level=int(sec.get("level", 1)))
        for p_text in sec.get("paragraphs", []):
            doc.add_paragraph(str(p_text))
        for b_text in sec.get("bullets", []):
            doc.add_paragraph(str(b_text), style="List Bullet")
        rows = sec.get("table")
        if rows and isinstance(rows, list) and len(rows) > 0:
            cols = max(len(r) for r in rows)
            tbl = doc.add_table(rows=len(rows), cols=cols)
            tbl.style = "Table Grid"
            for r_i, r_vals in enumerate(rows):
                for c_i, val in enumerate(r_vals):
                    tbl.cell(r_i, c_i).text = str(val)

    rows = spec.get("table")
    if rows and isinstance(rows, list) and len(rows) > 0:
        cols = max(len(r) for r in rows)
        tbl = doc.add_table(rows=len(rows), cols=cols)
        tbl.style = "Table Grid"
        for r_i, r_vals in enumerate(rows):
            for c_i, val in enumerate(r_vals):
                tbl.cell(r_i, c_i).text = str(val)

    doc.save(output_path)
    return {"success": True, "output_path": output_path, "message": f"Word belgesi kaydedildi: {output_path}"}


# ---------------------------------------------------------------------------
# 2. EXCEL (.XLSX / .CSV) OLUŞTURMA VE DÜZENLEME
# ---------------------------------------------------------------------------
def handle_xlsx(spec):
    import openpyxl
    from openpyxl.styles import Font

    action = spec.get("action", "create")
    input_path = spec.get("input_path")
    output_path = spec.get("output_path") or input_path
    if not output_path:
        return {"success": False, "error": "output_path zorunludur."}
    ensure_parent(output_path)

    if output_path.lower().endswith(".csv"):
        rows = spec.get("rows", [])
        headers = spec.get("headers")
        with open(output_path, "w", encoding="utf-8-sig", newline="") as f:
            writer = csv.writer(f)
            if headers:
                writer.writerow(headers)
            writer.writerows(rows)
        return {"success": True, "output_path": output_path, "message": f"CSV tablosu kaydedildi: {output_path}"}

    if input_path and os.path.isfile(input_path) and action != "create":
        wb = openpyxl.load_workbook(input_path)
    else:
        wb = openpyxl.Workbook()

    sheet_name = spec.get("sheet_name")
    ws = wb[sheet_name] if (sheet_name and sheet_name in wb.sheetnames) else wb.active
    if sheet_name and sheet_name not in wb.sheetnames:
        if action == "create":
            ws.title = sheet_name
        else:
            ws = wb.create_sheet(title=sheet_name)

    if action == "update_cells":
        cells = spec.get("cells", {})
        for coord, val in cells.items():
            ws[str(coord)] = val
        for row in spec.get("append_rows", []):
            ws.append(row)
    else:
        sheets = spec.get("sheets")
        if sheets and isinstance(sheets, list):
            for idx, sh_def in enumerate(sheets):
                sname = sh_def.get("name", f"Sayfa{idx + 1}")
                cur_ws = wb.active if idx == 0 else wb.create_sheet(title=sname)
                cur_ws.title = sname
                if sh_def.get("headers"):
                    cur_ws.append(sh_def["headers"])
                    for cell in cur_ws[1]:
                        cell.font = Font(bold=True)
                for r in sh_def.get("rows", []):
                    cur_ws.append(r)
        else:
            if spec.get("headers"):
                ws.append(spec["headers"])
                for cell in ws[1]:
                    cell.font = Font(bold=True)
            for r in spec.get("rows", []):
                ws.append(r)
            for coord, val in spec.get("cells", {}).items():
                ws[str(coord)] = val

    # Otomatik sütun genişliği ayarı
    for sheet in wb.worksheets:
        for col in sheet.columns:
            max_len = 0
            col_letter = col[0].column_letter
            for cell in col:
                if cell.value is not None:
                    max_len = max(max_len, len(str(cell.value)))
            sheet.column_dimensions[col_letter].width = min(max(max_len + 3, 10), 50)

    wb.save(output_path)
    return {"success": True, "output_path": output_path, "message": f"Excel dosyası kaydedildi: {output_path}"}


# ---------------------------------------------------------------------------
# 3. POWERPOINT (.PPTX) OLUŞTURMA VE DÜZENLEME
# ---------------------------------------------------------------------------
def handle_pptx(spec):
    from pptx import Presentation

    action = spec.get("action", "create")
    input_path = spec.get("input_path")
    output_path = spec.get("output_path") or input_path
    if not output_path:
        return {"success": False, "error": "output_path zorunludur."}
    ensure_parent(output_path)

    prs = (
        Presentation(input_path)
        if (input_path and os.path.isfile(input_path) and action != "create")
        else Presentation()
    )

    if action == "replace_text":
        replacements = spec.get("replacements", {})
        if not replacements and spec.get("find"):
            replacements = {spec["find"]: spec.get("replace", "")}
        count = 0
        for slide in prs.slides:
            for shape in slide.shapes:
                if getattr(shape, "has_text_frame", False):
                    for para in shape.text_frame.paragraphs:
                        for k, v in replacements.items():
                            if k in para.text:
                                para.text = para.text.replace(k, str(v))
                                count += 1
        prs.save(output_path)
        return {"success": True, "output_path": output_path, "message": f"Sunumda {count} metin güncellendi."}

    for s_idx, s_def in enumerate(spec.get("slides", [])):
        stitle = str(s_def.get("title", f"Slayt {s_idx + 1}"))
        bullets = s_def.get("bullets", [])
        body = s_def.get("content", "")
        if s_idx == 0 and action == "create" and not bullets and s_def.get("subtitle"):
            slide = prs.slides.add_slide(prs.slide_layouts[0])
            slide.shapes.title.text = stitle
            if len(slide.placeholders) > 1:
                slide.placeholders[1].text = str(s_def["subtitle"])
        else:
            slide = prs.slides.add_slide(prs.slide_layouts[1])
            slide.shapes.title.text = stitle
            tf = slide.placeholders[1].text_frame
            tf.clear()
            items = bullets if bullets else ([body] if body else [])
            for b_i, item in enumerate(items):
                p = tf.paragraphs[0] if b_i == 0 else tf.add_paragraph()
                p.text = str(item)
        if s_def.get("notes"):
            slide.notes_slide.notes_text_frame.text = str(s_def["notes"])

    prs.save(output_path)
    return {"success": True, "output_path": output_path, "message": f"PowerPoint sunumu kaydedildi: {output_path}"}


# ---------------------------------------------------------------------------
# 4. PDF OLUŞTURMA, BİRLEŞTİRME, BÖLME VE DÜZENLEME
# ---------------------------------------------------------------------------
def handle_pdf(spec):
    import pymupdf as fitz

    action = spec.get("action", "create")
    input_path = spec.get("input_path")
    output_path = spec.get("output_path") or input_path
    if not output_path:
        return {"success": False, "error": "output_path zorunludur."}
    ensure_parent(output_path)

    if action == "merge":
        inputs = spec.get("input_paths", [])
        if not inputs:
            return {"success": False, "error": "merge için input_paths listesi gerekli."}
        merged = fitz.open()
        for p_in in inputs:
            with fitz.open(p_in) as src:
                merged.insert_pdf(src)
        merged.save(output_path)
        merged.close()
        return {"success": True, "output_path": output_path, "message": f"{len(inputs)} PDF birleştirildi."}

    if action == "extract_pages":
        start_p = max(1, int(spec.get("start_page", 1))) - 1
        end_p = int(spec.get("end_page", start_p + 1)) - 1
        with fitz.open(input_path) as src:
            out = fitz.open()
            out.insert_pdf(src, from_page=start_p, to_page=min(end_p, len(src) - 1))
            out.save(output_path)
            out.close()
        return {"success": True, "output_path": output_path, "message": f"Sayfa aralığı çıkarıldı: {output_path}"}

    if action == "rotate":
        angle = int(spec.get("angle", 90))
        doc = fitz.open(input_path)
        for page in doc:
            page.set_rotation((page.rotation + angle) % 360)
        doc.save(output_path)
        doc.close()
        return {"success": True, "output_path": output_path, "message": f"PDF sayfaları {angle}° döndürüldü."}

    if action == "stamp_text":
        stamp = str(spec.get("text", "FerIDE"))
        doc = fitz.open(input_path)
        for page in doc:
            page.insert_text((36, 36), stamp, fontsize=11, color=(0.2, 0.3, 0.8))
        doc.save(output_path)
        doc.close()
        return {"success": True, "output_path": output_path, "message": f"PDF damgalandı: {output_path}"}

    # Varsayılan: Tam Türkçe UTF-8 destekli zengin PDF üretimi (fitz.Story HTML motoru)
    title = html.escape(str(spec.get("title", "")))
    html_parts = [
        "<html><body style='font-family: sans-serif; font-size: 11pt; line-height: 1.5; color: #1a1a1a;'>"
    ]
    if title:
        html_parts.append(f"<h1 style='color:#1e3a8a;'>{title}</h1><hr/>")
    for p_text in spec.get("paragraphs", []):
        html_parts.append(f"<p>{html.escape(str(p_text))}</p>")
    for sec in spec.get("sections", []):
        if sec.get("heading"):
            html_parts.append(f"<h2 style='color:#1e40af;'>{html.escape(str(sec['heading']))}</h2>")
        for p_text in sec.get("paragraphs", []):
            html_parts.append(f"<p>{html.escape(str(p_text))}</p>")
        if sec.get("bullets"):
            html_parts.append("<ul>")
            for b in sec["bullets"]:
                html_parts.append(f"<li>{html.escape(str(b))}</li>")
            html_parts.append("</ul>")
        if sec.get("table"):
            html_parts.append("<table border='1' cellspacing='0' cellpadding='5' style='border-collapse:collapse;'>")
            for r_i, row in enumerate(sec["table"]):
                tag = "th" if r_i == 0 else "td"
                cells = "".join(f"<{tag}>{html.escape(str(c))}</{tag}>" for c in row)
                html_parts.append(f"<tr>{cells}</tr>")
            html_parts.append("</table><br/>")
    html_parts.append("</body></html>")

    story = fitz.Story(html="".join(html_parts))
    writer = fitz.DocumentWriter(output_path)
    mediabox = fitz.paper_rect("a4")
    where = mediabox + (42, 42, -42, -42)
    more = True
    while more:
        device = writer.begin_page(mediabox)
        more, _ = story.place(where)
        story.draw(device)
        writer.end_page()
    writer.close()
    return {"success": True, "output_path": output_path, "message": f"PDF belgesi oluşturuldu: {output_path}"}


# ---------------------------------------------------------------------------
# 5. AUTOCAD (.DWG & .DXF) OLUŞTURMA, DÜZENLEME VE DÖNÜŞTÜRME
# ---------------------------------------------------------------------------
def handle_cad(spec):
    import ezdxf

    action = spec.get("action", "create")
    input_path = spec.get("input_path")
    output_path = spec.get("output_path") or input_path
    if not output_path:
        return {"success": False, "error": "output_path zorunludur (.dxf, .dwg, .png, .svg veya .pdf)."}
    ensure_parent(output_path)

    temp_in_dxf = None
    temp_out_dxf = None

    try:
        if input_path and os.path.isfile(input_path) and action != "create":
            if input_path.lower().endswith(".dwg"):
                dwg2dxf_bin = find_binary("dwg2dxf")
                if not dwg2dxf_bin:
                    return {"success": False, "error": "DWG okumak için dwg2dxf bulunamadı."}
                fd, temp_in_dxf = tempfile.mkstemp(suffix=".dxf", prefix="feride_cad_in_")
                os.close(fd)
                os.unlink(temp_in_dxf)
                subprocess.run([dwg2dxf_bin, "-y", "-o", temp_in_dxf, input_path], capture_output=True, timeout=60)
                doc = ezdxf.readfile(temp_in_dxf)
            else:
                doc = ezdxf.readfile(input_path)
        else:
            doc = ezdxf.new("R2018", setup=True)
            unit_name = str(spec.get("units", "cm")).lower()
            unit_codes = {"mm": 4, "cm": 5, "m": 6, "inch": 1, "ft": 2}
            doc.header["$INSUNITS"] = unit_codes.get(unit_name, 5)

        msp = doc.modelspace()

        for op in spec.get("operations", []):
            kind = op.get("op", "")
            layer = str(op.get("layer", "0"))
            if layer != "0" and layer not in doc.layers:
                doc.layers.add(layer, color=int(op.get("color", 7)))

            if kind == "add_layer":
                lname = str(op.get("name", "KATMAN"))
                if lname not in doc.layers:
                    doc.layers.add(lname, color=int(op.get("color", 7)))
            elif kind == "delete_layer":
                lname = str(op.get("name", ""))
                for ent in list(msp):
                    if getattr(ent.dxf, "layer", "") == lname:
                        msp.delete_entity(ent)
                if lname in doc.layers and lname != "0":
                    doc.layers.remove(lname)
            elif kind == "add_line":
                msp.add_line(tuple(op["start"]), tuple(op["end"]), dxfattribs={"layer": layer})
            elif kind == "add_rect":
                ox, oy = op.get("origin", [0, 0])
                w, h = float(op["width"]), float(op["height"])
                pts = [(ox, oy), (ox + w, oy), (ox + w, oy + h), (ox, oy + h)]
                msp.add_lwpolyline(pts, close=True, dxfattribs={"layer": layer})
                if op.get("label"):
                    th = float(op.get("text_height", max(min(w, h) * 0.08, 2.5)))
                    txt_ent = msp.add_text(
                        str(op["label"]),
                        dxfattribs={"layer": layer, "height": th},
                    )
                    txt_ent.dxf.insert = (ox + w * 0.12, oy + h * 0.45)
            elif kind == "add_polyline":
                pts = [tuple(pt) for pt in op["points"]]
                msp.add_lwpolyline(pts, close=bool(op.get("closed", False)), dxfattribs={"layer": layer})
            elif kind == "add_circle":
                msp.add_circle(tuple(op["center"]), float(op["radius"]), dxfattribs={"layer": layer})
            elif kind == "add_arc":
                msp.add_arc(
                    tuple(op["center"]),
                    float(op["radius"]),
                    float(op.get("start_angle", 0)),
                    float(op.get("end_angle", 180)),
                    dxfattribs={"layer": layer},
                )
            elif kind == "add_text":
                t_ent = msp.add_text(
                    str(op["text"]),
                    dxfattribs={
                        "layer": layer,
                        "height": float(op.get("height", 10.0)),
                        "rotation": float(op.get("rotation", 0.0)),
                    },
                )
                t_ent.dxf.insert = tuple(op.get("pos", [0, 0]))
            elif kind == "replace_text":
                f_str = str(op.get("find", ""))
                r_str = str(op.get("replace", ""))
                for ent in msp:
                    if ent.dxftype() in ("TEXT", "MTEXT") and f_str:
                        cur = getattr(ent.dxf, "text", "")
                        if f_str in cur:
                            ent.dxf.text = cur.replace(f_str, r_str)

        out_ext = os.path.splitext(output_path)[1].lower()
        preview_path = spec.get("preview_path")

        if out_ext in [".png", ".svg", ".pdf"]:
            _render_cad_doc(doc, output_path)
            return {
                "success": True,
                "output_path": output_path,
                "message": f"CAD çizimi görsel/vektörel olarak dışa aktarıldı: {output_path}",
            }

        if out_ext == ".dwg":
            dxf2dwg_bin = find_binary("dxf2dwg")
            # R2000 (AC1015) LibreDWG dxf2dwg yazıcısıyla en yüksek uyumluluğu sağlar
            fd, temp_out_dxf = tempfile.mkstemp(suffix=".dxf", prefix="feride_cad_out_")
            os.close(fd)
            doc.saveas(temp_out_dxf)
            if not dxf2dwg_bin:
                fallback_dxf = os.path.splitext(output_path)[0] + ".dxf"
                shutil.copyfile(temp_out_dxf, fallback_dxf)
                return {
                    "success": True,
                    "output_path": fallback_dxf,
                    "message": f"dxf2dwg bulunamadığı için çizim AutoCAD uyumlu DXF olarak kaydedildi: {fallback_dxf}",
                }
            if os.path.exists(output_path):
                os.unlink(output_path)
            subprocess.run([dxf2dwg_bin, "-y", "-o", output_path, temp_out_dxf], capture_output=True, timeout=60)
            if not os.path.isfile(output_path) or os.path.getsize(output_path) == 0:
                fallback_dxf = os.path.splitext(output_path)[0] + ".dxf"
                shutil.copyfile(temp_out_dxf, fallback_dxf)
                return {
                    "success": True,
                    "output_path": fallback_dxf,
                    "message": f"Çizim AutoCAD uyumlu DXF olarak kaydedildi: {fallback_dxf}",
                }
        else:
            doc.saveas(output_path)

        if preview_path:
            ensure_parent(preview_path)
            _render_cad_doc(doc, preview_path)

        return {
            "success": True,
            "output_path": output_path,
            "preview_path": preview_path,
            "message": f"AutoCAD çizimi başarıyla kaydedildi: {output_path}",
        }
    except Exception as e:
        return {"success": False, "error": f"CAD işlemi başarısız: {e}"}
    finally:
        for tmp in (temp_in_dxf, temp_out_dxf):
            if tmp and os.path.exists(tmp):
                try:
                    os.unlink(tmp)
                except Exception:
                    pass


def _render_cad_doc(doc, out_file):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from ezdxf.addons.drawing import Frontend, RenderContext
    from ezdxf.addons.drawing.matplotlib import MatplotlibBackend

    fig = plt.figure(figsize=(11, 8), dpi=180)
    ax = fig.add_axes([0, 0, 1, 1])
    ctx = RenderContext(doc)
    backend = MatplotlibBackend(ax)
    Frontend(ctx, backend).draw_layout(doc.modelspace(), finalize=True)
    fig.savefig(out_file, dpi=180, bbox_inches="tight")
    plt.close(fig)


# ---------------------------------------------------------------------------
# 6. GÖRSEL DÜZENLEME (RESIZE, CROP, ROTATE, CONVERT, ANNOTATE, FILTER)
# ---------------------------------------------------------------------------
def handle_image(spec):
    from PIL import Image, ImageDraw, ImageEnhance, ImageOps

    input_path = spec.get("input_path")
    output_path = spec.get("output_path") or input_path
    if not input_path or not os.path.isfile(input_path):
        return {"success": False, "error": "Geçerli bir input_path gerekli."}
    if not output_path:
        return {"success": False, "error": "output_path gerekli."}
    ensure_parent(output_path)

    with Image.open(input_path) as raw_img:
        img = raw_img.copy()

        if spec.get("grayscale"):
            img = ImageOps.grayscale(img)

        if spec.get("rotate"):
            img = img.rotate(-float(spec["rotate"]), expand=True)

        if spec.get("crop"):
            # [left, top, right, bottom]
            img = img.crop(tuple(int(x) for x in spec["crop"]))

        if spec.get("width") or spec.get("height"):
            orig_w, orig_h = img.size
            w = int(spec.get("width") or round(orig_w * (int(spec["height"]) / orig_h)))
            h = int(spec.get("height") or round(orig_h * (w / orig_w)))
            img = img.resize((w, h), Image.Resampling.LANCZOS)

        if spec.get("brightness"):
            img = ImageEnhance.Brightness(img).enhance(float(spec["brightness"]))
        if spec.get("contrast"):
            img = ImageEnhance.Contrast(img).enhance(float(spec["contrast"]))
        if spec.get("sharpness"):
            img = ImageEnhance.Sharpness(img).enhance(float(spec["sharpness"]))

        if spec.get("annotate_text"):
            if img.mode not in ("RGB", "RGBA"):
                img = img.convert("RGBA")
            draw = ImageDraw.Draw(img)
            pos = tuple(spec.get("text_pos", [20, 20]))
            draw.text(pos, str(spec["annotate_text"]), fill=spec.get("text_color", "white"))

        out_ext = os.path.splitext(output_path)[1].lower()
        if out_ext in (".jpg", ".jpeg") and img.mode in ("RGBA", "P"):
            img = img.convert("RGB")

        img.save(output_path)
        return {
            "success": True,
            "output_path": output_path,
            "size": f"{img.size[0]}x{img.size[1]}",
            "message": f"Görsel düzenlendi ve kaydedildi: {output_path}",
        }


# ---------------------------------------------------------------------------
# 7. SES & MÜZİK DÜZENLEME (TRIM, CONVERT, MERGE, VOLUME, SPEED, ID3 TAGS)
# ---------------------------------------------------------------------------
def handle_audio(spec):
    action = spec.get("action", "convert")
    input_path = spec.get("input_path")
    output_path = spec.get("output_path")
    if not output_path:
        return {"success": False, "error": "output_path zorunludur."}
    ensure_parent(output_path)

    ffmpeg_bin = shutil.which("ffmpeg")
    if not ffmpeg_bin:
        return {"success": False, "error": "Ses düzenleme için ffmpeg bulunamadı."}

    if action == "merge":
        inputs = spec.get("input_paths", [])
        if len(inputs) < 2:
            return {"success": False, "error": "Birleştirme için en az 2 ses dosyası gerekli."}
        fd, list_path = tempfile.mkstemp(suffix=".txt", prefix="feride_audio_")
        os.close(fd)
        try:
            with open(list_path, "w", encoding="utf-8") as f:
                for p_in in inputs:
                    safe = os.path.abspath(p_in).replace("'", "'\\''")
                    f.write(f"file '{safe}'\n")
            pr = subprocess.run(
                [ffmpeg_bin, "-y", "-f", "concat", "-safe", "0", "-i", list_path, output_path],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if pr.returncode != 0:
                return {"success": False, "error": pr.stderr[-500:]}
            return {"success": True, "output_path": output_path, "message": f"{len(inputs)} ses dosyası birleştirildi."}
        finally:
            if os.path.exists(list_path):
                os.unlink(list_path)

    if not input_path or not os.path.isfile(input_path):
        return {"success": False, "error": f"Ses dosyası bulunamadı: {input_path}"}

    cmd = [ffmpeg_bin, "-y"]
    if spec.get("start_sec") is not None:
        cmd.extend(["-ss", str(spec["start_sec"])])
    if spec.get("end_sec") is not None:
        cmd.extend(["-to", str(spec["end_sec"])])
    cmd.extend(["-i", input_path])

    afilters = []
    if spec.get("normalize"):
        afilters.append("loudnorm")
    if spec.get("db_change") is not None:
        afilters.append(f"volume={float(spec['db_change'])}dB")
    if spec.get("speed") is not None:
        spd = max(0.5, min(2.0, float(spec["speed"])))
        afilters.append(f"atempo={spd}")
    if afilters:
        cmd.extend(["-af", ",".join(afilters)])

    for m_key in ("title", "artist", "album", "genre", "date"):
        if spec.get(m_key):
            cmd.extend(["-metadata", f"{m_key}={spec[m_key]}"])

    if spec.get("bitrate"):
        cmd.extend(["-b:a", str(spec["bitrate"])])

    cmd.append(output_path)
    pr = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if pr.returncode != 0:
        return {"success": False, "error": f"ffmpeg hatası: {pr.stderr[-600:]}"}
    return {"success": True, "output_path": output_path, "message": f"Ses/müzik dosyası işlendi: {output_path}"}


def dispatch(spec):
    category = str(spec.get("category", "")).lower().strip()
    out_ext = os.path.splitext(str(spec.get("output_path", "")))[1].lower()

    if not category:
        if out_ext == ".docx":
            category = "docx"
        elif out_ext in (".xlsx", ".csv"):
            category = "xlsx"
        elif out_ext == ".pptx":
            category = "pptx"
        elif out_ext == ".pdf":
            category = "pdf"
        elif out_ext in (".dwg", ".dxf"):
            category = "cad"
        elif out_ext in (".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tiff"):
            category = "image"
        elif out_ext in (".mp3", ".wav", ".flac", ".ogg", ".m4a", ".aac", ".opus"):
            category = "audio"

    handlers = {
        "docx": handle_docx,
        "word": handle_docx,
        "xlsx": handle_xlsx,
        "excel": handle_xlsx,
        "csv": handle_xlsx,
        "pptx": handle_pptx,
        "powerpoint": handle_pptx,
        "pdf": handle_pdf,
        "cad": handle_cad,
        "dwg": handle_cad,
        "dxf": handle_cad,
        "autocad": handle_cad,
        "image": handle_image,
        "audio": handle_audio,
        "music": handle_audio,
    }

    fn = handlers.get(category)
    if not fn:
        return {
            "success": False,
            "error": f"Desteklenmeyen kategori: '{category}'. Desteklenenler: docx, xlsx, pptx, pdf, cad (dwg/dxf), image, audio.",
        }
    return fn(spec)


if __name__ == "__main__":
    try:
        if len(sys.argv) >= 2 and sys.argv[1] == "--stdin":
            raw = sys.stdin.read()
        elif len(sys.argv) >= 2:
            raw = sys.argv[1]
        else:
            print(json.dumps({"success": False, "error": "JSON parametre bekleniyor."}))
            sys.exit(1)

        payload = json.loads(raw)
        res = dispatch(payload)
        print(json.dumps(res, ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False))
        sys.exit(1)

