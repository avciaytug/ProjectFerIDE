#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE kadın sesi kurulumu (Feride — Ahenk Cep) — Linux / Windows / macOS
========================================================================
Kurulan:
  * PyTorch (yalnızca CPU sürümü), ema-lightning 1.1.2, trnorm (Türkçe metin normalleştirme)
  * Model: https://huggingface.co/ozgurguler/ahenk-cep-tr  →  <FerIDE>/models/ahenk_cep/
    Dosyalar, model sayfasında yayınlanan SHA-256 özetleriyle doğrulanır; tutmazsa kurulmaz.

Lisans: Model ağırlıkları CC BY 4.0 — "Ahenk Cep, Ahenk (https://github.com/ozguradmin/ahenk-turkish-tts), CC BY 4.0".
Ses tasarlanmış sentetik bir sestir (gerçek bir kişiye ait değildir).

Kullanım:  <FerIDE venv python>  scripts/setup_voice.py
"""

import hashlib
import os
import platform
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
DEST = os.path.join(ROOT, "models", "ahenk_cep")
REPO = "ozgurguler/ahenk-cep-tr"

# Model sayfasında (README) yayınlanan özetler.
EXPECTED = {
    "student.pt": "020e2d31cb51847a9f06376febbb6ba9329ded7c3084a7fdd4f45adada3f23d3",
    "decoder.pt": "5caeede49ce987a94e31fc8a58bed569e993c820fe6f1c9b301d6c489d3cbbd1",
    "ahenk_cep.py": "01fb2b741b9991888305c9bd9fcadeba1f23025c7a92b738be379f6fcb36b332",
}


def pip(*args):
    cmd = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", *args]
    print("→", " ".join(cmd), flush=True)
    subprocess.check_call(cmd)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main():
    print("=== FerIDE kadın sesi (Feride — Ahenk Cep) kuruluyor ===", flush=True)

    # 1) Bağımlılıklar
    try:
        import torch  # noqa: F401
        print("✓ PyTorch zaten kurulu")
    except ImportError:
        if platform.system() == "Darwin":
            pip("torch")
        else:
            pip("torch", "--index-url", "https://download.pytorch.org/whl/cpu")
    pip("numpy", "huggingface_hub", "ema-lightning==1.1.2",
        "git+https://github.com/ozguradmin/ahenk-turkish-tts")

    # 2) Model dosyaları
    from huggingface_hub import hf_hub_download

    os.makedirs(DEST, exist_ok=True)
    for name, digest in EXPECTED.items():
        target = os.path.join(DEST, name)
        if os.path.isfile(target) and sha256(target) == digest:
            print(f"✓ {name} zaten doğrulanmış")
            continue
        path = hf_hub_download(REPO, name)
        got = sha256(path)
        if got != digest:
            raise SystemExit(f"✗ {name} özeti tutmadı ({got}); güvenlik nedeniyle kurulmadı.")
        with open(path, "rb") as src, open(target, "wb") as dst:
            dst.write(src.read())
        print(f"✓ {name} indirildi ve doğrulandı")

    with open(os.path.join(DEST, "LICENSE_ATTRIBUTION.txt"), "w", encoding="utf-8") as f:
        f.write("Ahenk Cep, Ahenk (https://github.com/ozguradmin/ahenk-turkish-tts), CC BY 4.0\n"
                "Inference code ahenk_cep.py: Apache-2.0. Base model EMA Lightning: Apache-2.0.\n"
                "Synthetic designed voice (f022); not a real person's voice.\n")

    # 3) Deneme
    sys.path.insert(0, DEST)
    from ahenk_cep import AhenkCep

    tts = AhenkCep(os.path.join(DEST, "student.pt"), os.path.join(DEST, "decoder.pt"))
    audio, sr = tts.say("Merhaba, ben Feride.")
    print(f"✓ Deneme sentezi başarılı ({len(audio) / sr:.2f} sn, {sr} Hz)")
    print("=== Kurulum tamam. FerIDE'yi yeniden başlatın; Ayarlar > Genel > Ses ve Konuşma'dan seçebilirsiniz. ===")


if __name__ == "__main__":
    main()
