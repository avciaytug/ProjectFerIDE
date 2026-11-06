#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE Piper TTS Sunucusu (v5.3.4 — Tamamen Lokal + Çoklu Platform)
===================================================================
Birincil: Piper TTS (`models/piper/tr_TR-fahrettin-medium.onnx`) — 100% çevrimdışı doğal Türkçe.
Yedek: macOS `say`, Windows `System.Speech`, Linux `espeak-ng` (Piper çalışmazsa bile ses kesilmez).
Port: 5050 (`http://127.0.0.1:5050/tts`)
"""

import io
import logging
import os
import platform
import re
import shutil
import subprocess
import tempfile
import wave
from flask import Flask, request, send_file

logging.basicConfig(level=logging.INFO, format="%(asctime)s [TTS] %(message)s")
log = logging.getLogger("feride-piper")

app = Flask(__name__)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
APP_ROOT = os.environ.get("FERIDE_ROOT") or os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
MODEL_PATH = os.path.join(APP_ROOT, "models", "piper", "tr_TR-fahrettin-medium.onnx")

_voice = None
_engine_name = "fallback"

try:
    from piper import PiperVoice

    if os.path.isfile(MODEL_PATH):
        log.info("Piper Türkçe ses modeli yükleniyor: %s", MODEL_PATH)
        _voice = PiperVoice.load(MODEL_PATH)
        _engine_name = "piper"
        log.info("✅ Piper modeli hazır. SampleRate: %s Hz", _voice.config.sample_rate)
except Exception as e:
    log.warning("Piper yüklenemedi, işletim sistemi yerel TTS yedeği kullanılacak: %s", e)


def clean_text_for_speech(text: str) -> str:
    """LLM çıktısından konuşmaya uygun olmayan düşünme/kod/JSON bloklarını temizler."""
    if not text:
        return ""

    text = re.sub(r"<think>[\s\S]*?</think>", "", text)
    text = re.sub(r"<tool_call>[\s\S]*?</tool_call>", "", text)
    text = re.sub(r"```[\s\S]*?```", "", text)
    text = re.sub(r"\{[^}]*\}", "", text)
    text = re.sub(r"\[[^\]]*\]", "", text)
    text = re.sub(r"`[^`]+`", "", text)
    text = re.sub(r"\*+", "", text)
    text = re.sub(r"#+\s*", "", text)
    text = re.sub(r"[-*]\s+", "", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"[<>{}()\[\]|\\/@#$%^&=+~]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()

    return text if len(text) >= 2 else ""


def _synthesize_fallback_wav(text: str) -> bytes:
    sys_name = platform.system().lower()
    fd, out_wav = tempfile.mkstemp(suffix=".wav", prefix="feride_tts_fb_")
    os.close(fd)
    try:
        if sys_name == "darwin" and shutil.which("say"):
            fd_aiff, tmp_aiff = tempfile.mkstemp(suffix=".aiff")
            os.close(fd_aiff)
            try:
                subprocess.run(["say", "-o", tmp_aiff, text], check=True, timeout=20)
                if shutil.which("ffmpeg"):
                    subprocess.run(["ffmpeg", "-y", "-i", tmp_aiff, out_wav], check=True, timeout=20)
                    with open(out_wav, "rb") as f:
                        return f.read()
            finally:
                if os.path.exists(tmp_aiff):
                    os.remove(tmp_aiff)
        elif sys_name == "windows":
            ps_cmd = (
                "Add-Type -AssemblyName System.Speech; "
                "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
                f"$s.SetOutputToWaveFile('{out_wav}'); "
                f"$s.Speak({json_quote_ps(text)}); $s.Dispose()"
            )
            subprocess.run(["powershell", "-NoProfile", "-Command", ps_cmd], check=True, timeout=20)
            with open(out_wav, "rb") as f:
                return f.read()
        elif shutil.which("espeak-ng"):
            subprocess.run(["espeak-ng", "-v", "tr", "-w", out_wav, text], check=True, timeout=20)
            with open(out_wav, "rb") as f:
                return f.read()
    finally:
        if os.path.exists(out_wav):
            try:
                os.remove(out_wav)
            except Exception:
                pass
    raise RuntimeError("Uygun yerel TTS motoru bulunamadı.")


def json_quote_ps(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


@app.route("/tts", methods=["POST"])
def generate_tts():
    data = request.get_json(silent=True) or {}
    raw_text = (data.get("text") or "").strip()
    if not raw_text:
        return {"error": "Text is empty"}, 400

    text = clean_text_for_speech(raw_text)
    if not text:
        return {"error": "Text contained only non-speech content"}, 400

    log.info("🔊 Seslendiriliyor (%s): %s", _engine_name, text[:80])

    try:
        if _voice is not None:
            buf = io.BytesIO()
            with wave.open(buf, "wb") as w:
                _voice.synthesize_wav(text, w)
            buf.seek(0)
            return send_file(buf, mimetype="audio/wav", download_name="feride_tts.wav")
        else:
            wav_bytes = _synthesize_fallback_wav(text)
            return send_file(io.BytesIO(wav_bytes), mimetype="audio/wav", download_name="feride_tts.wav")
    except Exception as e:
        log.exception("❌ TTS üretim hatası")
        return {"error": str(e)}, 500


@app.route("/health", methods=["GET"])
def health():
    return {
        "status": "ok",
        "engine": _engine_name,
        "voice": "tr_TR-fahrettin-medium" if _voice is not None else "os-native",
        "sample_rate": _voice.config.sample_rate if _voice is not None else 22050,
    }


if __name__ == "__main__":
    port = 5050
    log.info("Piper TTS Sunucusu başlatıldı: http://127.0.0.1:%s", port)
    app.run(host="127.0.0.1", port=port)
