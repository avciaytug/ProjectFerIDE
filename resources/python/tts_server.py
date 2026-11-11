#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE Ses Sunucusu (TTS) — tamamen yerel — http://127.0.0.1:5050
=================================================================
Sesler:
  female  Feride — Ahenk Cep (Türkçe kadın sesi, 48 kHz, CC BY 4.0)
          models/ahenk_cep/  →  *.onnx (yalnızca onnxruntime+numpy)  veya
                                student.pt + decoder.pt + ahenk_cep.py (PyTorch)
  male    Erkek ses — Piper DFKI (models/piper/tr_TR-dfki-medium.onnx)

API:
  POST /tts     {"text": "...", "voice": "female"|"male", "speed": 1.0}  → audio/wav (int16)
  GET  /health  {"status": "ok", "voices": {"female": bool, "male": bool}, ...}

İstenen ses kurulu değilse diğer sese düşer; kullanılan ses X-Voice yanıt başlığında bildirilir.
Hiçbir istek bilgisayarın dışına çıkmaz.
"""

import os as _os
_os.environ.setdefault("HF_HUB_OFFLINE", "1")  # çalışma anında ağ yok: modeller yalnızca kurulumda iner
_os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
import io
import json
import logging
import os
import re
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

logging.basicConfig(level=logging.INFO, format="%(asctime)s [TTS] %(message)s")
log = logging.getLogger("feride-tts")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
APP_ROOT = os.environ.get("FERIDE_ROOT") or os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
MODELS = os.path.join(APP_ROOT, "models")
# Erkek ses: Piper DFKI. Eski kurulumlarda yalnızca yerelde kalmış fahrettin varsa o kullanılır
# (fahrettin, ses sahiplerinin isteğiyle Piper deposundan kaldırıldı; FerIDE artık indirmez).
PIPER_MODEL = os.path.join(MODELS, "piper", "tr_TR-dfki-medium.onnx")
if not os.path.isfile(PIPER_MODEL) and os.path.isfile(os.path.join(MODELS, "piper", "tr_TR-fahrettin-medium.onnx")):
    PIPER_MODEL = os.path.join(MODELS, "piper", "tr_TR-fahrettin-medium.onnx")
AHENK_DIR = os.path.join(MODELS, "ahenk_cep")
PORT = int(os.environ.get("FERIDE_TTS_PORT", "5050"))


# ----------------------------------------------------------------- metin
_EXTS = ["pdf", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "txt", "csv", "json", "png", "jpg", "jpeg",
         "mp3", "mp4", "wav", "zip", "py", "dart", "js", "ts", "html", "md", "dwg", "dxf", "odt", "ods"]

def clean_text_for_speech(text: str) -> str:
    """LLM çıktısından konuşulmayacak parçaları (kod, markdown, JSON, URL) ayıklar."""
    if not text:
        return ""
    text = re.sub(r"<think>[\s\S]*?</think>", "", text)
    text = re.sub(r"<tool_call>[\s\S]*?</tool_call>", "", text)
    text = re.sub(r"```[\s\S]*?```", " ", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"https?://\S+", "", text)
    # Dosya adları: "rapor.pdf" → "rapor nokta PDF" (uzantılar harf harf okunur)
    text = re.sub(r"(?<=\w)\.(" + "|".join(_EXTS) + r")\b",
                  lambda m: " nokta " + m.group(1).upper(), text, flags=re.I)
    text = re.sub(r"\{[^}]*\}", "", text)
    text = re.sub(r"[*_#>|~]+", "", text)
    text = re.sub(r"^\s*[-•]\s+", "", text, flags=re.M)
    text = re.sub(r"[<>{}\[\]\\^=+@$%]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) >= 2 else ""


def to_wav_bytes(audio: np.ndarray, sr: int) -> bytes:
    audio = np.asarray(audio, dtype=np.float32).reshape(-1)
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak > 1.0:
        audio = audio / peak
    pcm = (np.clip(audio, -1.0, 1.0) * 32767.0).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(sr))
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


# ---------------------------------------------------------------- sesler
class PiperVoiceEngine:
    name = "male"

    def __init__(self):
        from piper import PiperVoice  # noqa: WPS433 (isteğe bağlı bağımlılık)

        self.voice = PiperVoice.load(PIPER_MODEL)
        self.sr = self.voice.config.sample_rate

    def synth(self, text: str, speed: float) -> bytes:
        try:
            from piper import SynthesisConfig

            cfg = SynthesisConfig(length_scale=1.0 / max(0.5, min(2.0, speed)))
        except Exception:  # noqa: BLE001 — eski piper sürümleri
            cfg = None
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            if cfg is not None:
                self.voice.synthesize_wav(text, w, syn_config=cfg)
            else:
                self.voice.synthesize_wav(text, w)
        return buf.getvalue()


class AhenkTorchEngine:
    """Ahenk Cep, resmî PyTorch çıkarım koduyla (models/ahenk_cep/ahenk_cep.py)."""

    name = "female"

    def __init__(self):
        sys.path.insert(0, AHENK_DIR)
        from ahenk_cep import AhenkCep  # noqa: WPS433

        self.tts = AhenkCep(os.path.join(AHENK_DIR, "student.pt"), os.path.join(AHENK_DIR, "decoder.pt"))
        # İlk çağrı modelleri ısıtır; kullanıcı ilk cümlede beklemesin.
        self.tts.say("Merhaba.")

    def synth(self, text: str, speed: float) -> bytes:
        audio, sr = self.tts.say(text, speed=max(0.5, min(2.0, speed)), steps=12)
        return to_wav_bytes(np.asarray(audio), sr)


def _ahenk_available() -> bool:
    return all(os.path.isfile(os.path.join(AHENK_DIR, f)) for f in ("student.pt", "decoder.pt", "ahenk_cep.py"))


ENGINES: dict = {}
LOCK = threading.Lock()


def load_engines():
    if os.path.isfile(PIPER_MODEL):
        try:
            ENGINES["male"] = PiperVoiceEngine()
            log.info("✅ Erkek ses hazır (Piper: %s)", os.path.basename(PIPER_MODEL))
        except Exception as e:  # noqa: BLE001
            log.warning("Piper yüklenemedi: %s", e)
    if _ahenk_available():
        try:
            ENGINES["female"] = AhenkTorchEngine()
            log.info("✅ Kadın ses hazır (Feride — Ahenk Cep)")
        except Exception as e:  # noqa: BLE001
            log.warning("Ahenk Cep yüklenemedi: %s", e)
    else:
        log.info("ℹ️ Kadın ses modeli (models/ahenk_cep) kurulu değil; erkek sese düşülecek.")


def synthesize(text: str, voice: str, speed: float):
    engine = ENGINES.get(voice) or ENGINES.get("female") or ENGINES.get("male")
    if engine is None:
        raise RuntimeError("Hiçbir ses modeli yüklenemedi.")
    with LOCK:  # modeller iş parçacığı güvenli değil
        return engine.synth(text, speed), engine.name


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, obj: dict):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        """Content-Length veya chunked aktarım kodlamasıyla gelen gövdeyi okur."""
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            body = bytearray()
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
                if len(body) > 1_000_000:
                    break
            return bytes(body)
        length = min(int(self.headers.get("Content-Length", "0") or 0), 1_000_000)
        return self.rfile.read(length) if length > 0 else b""

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/health"):
            self._json(200, {
                "status": "ok",
                "voices": {"female": "female" in ENGINES, "male": "male" in ENGINES},
                "engine": ",".join(sorted(ENGINES)),
            })
        else:
            self._json(404, {"error": "bulunamadı"})

    def do_POST(self):  # noqa: N802
        if not self.path.startswith("/tts"):
            self._json(404, {"error": "bulunamadı"})
            return
        try:
            data = json.loads(self._read_body() or b"{}")
        except Exception:  # noqa: BLE001
            self._json(400, {"error": "geçersiz JSON"})
            return
        text = clean_text_for_speech(str(data.get("text", "")))
        if not text:
            self._json(400, {"error": "seslendirilecek metin yok"})
            return
        voice = str(data.get("voice", "female"))
        try:
            speed = float(data.get("speed", 1.0))
        except (TypeError, ValueError):
            speed = 1.0
        try:
            wav, used = synthesize(text, voice, speed)
        except Exception as e:  # noqa: BLE001
            log.exception("TTS hatası")
            self._json(500, {"error": str(e)})
            return
        log.info("🔊 (%s) %s", used, text[:80])
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.send_header("X-Voice", used)
        self.end_headers()
        self.wfile.write(wav)

    def log_message(self, *_):  # sessiz erişim günlüğü
        pass


if __name__ == "__main__":
    load_engines()
    log.info("FerIDE ses sunucusu: http://127.0.0.1:%s  (sesler: %s)", PORT, ", ".join(sorted(ENGINES)) or "yok")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
