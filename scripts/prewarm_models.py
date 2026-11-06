#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE Model Ön-Isıtma (v5.3.7)
===============================
Mevcut ortama göre (hafif venv veya tam ROCm feride_env) ses modellerini ön-ısıtır.
"""
import os

os.environ.setdefault("HSA_OVERRIDE_GFX_VERSION", "11.0.0")
os.environ.setdefault("COQUI_TOS_AGREED", "1")

HOME_DIR = os.path.expanduser("~")
TORCH_HUB_DIR = os.path.join(HOME_DIR, ".cache", "torch_hub_feride")


def main() -> None:
    try:
        import torch

        os.makedirs(TORCH_HUB_DIR, exist_ok=True)
        torch.hub.set_dir(TORCH_HUB_DIR)
        device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"[prewarm] torch={torch.__version__} device={device}")

        try:
            torch.hub.load(repo_or_dir="snakers4/silero-vad", model="silero_vad", force_reload=False, onnx=False)
            print("[prewarm] VAD_OK")
        except Exception as e:
            print(f"[prewarm] VAD_SKIP: {e}")

        try:
            import whisper

            whisper.load_model("turbo", device=device)
            print(f"[prewarm] WHISPER_OK device={device}")
        except Exception as e:
            print(f"[prewarm] WHISPER_SKIP: {e}")

        try:
            from TTS.api import TTS

            TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)
            print(f"[prewarm] XTTS_OK device={device}")
        except Exception as e:
            print(f"[prewarm] XTTS_SKIP: {e}")
    except ImportError:
        try:
            from faster_whisper import WhisperModel

            cache_dir = os.path.join(HOME_DIR, ".feride", "cache", "whisper")
            os.makedirs(cache_dir, exist_ok=True)
            WhisperModel("small", device="cpu", compute_type="int8", download_root=cache_dir)
            print("[prewarm] FASTER_WHISPER_OK")
        except Exception as e:
            print(f"[prewarm] FASTER_WHISPER_SKIP: {e}")

    print("[prewarm] DONE")


if __name__ == "__main__":
    main()
