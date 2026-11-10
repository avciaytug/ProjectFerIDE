#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE STT (Speech-to-Text) Sunucusu (v5.3.8 — Linux / Windows / macOS)
=======================================================================
1) PyAV `metadata_errors` uyumsuzluğundan %100 bağımsız: gelen her türlü ses
   verisini (WAV, WebM, M4A, MP3, OGG, 48kHz/44.1kHz/16kHz, stereo/mono)
   doğrudan 16kHz mono float32 NumPy dizisine çevirip Whisper'a besler.
2) Sıfır internet (Offline) hazır başlangıç: Paket içindeki gömülü
   `models/whisper/base` modelini 0.5 saniyede açar; diskte `small` önbelleği
   varsa onu kullanır, yoksa arka planda sessizce `small` modelini indirip
   canlı geçiş (hot-swap) yapar.
3) ThreadingHTTPServer (Port 5052): /health ve /transcribe eşzamanlı çalışır.
"""

import os as _os
_os.environ.setdefault("HF_HUB_OFFLINE", "1")  # çalışma anında ağ yok: modeller yalnızca kurulumda iner
_os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
import argparse
import io
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

HOME_DIR = os.path.expanduser("~")
FERIDE_DIR = os.path.join(HOME_DIR, ".feride")
LOG_DIR = os.path.join(FERIDE_DIR, "logs")
CACHE_DIR = os.path.join(FERIDE_DIR, "cache", "whisper")
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(CACHE_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [STT] %(message)s",
    handlers=[
        logging.FileHandler(os.path.join(LOG_DIR, "stt_server.log"), encoding="utf-8"),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger("feride-stt")

parser = argparse.ArgumentParser(description="FerIDE STT Server")
parser.add_argument("--device", type=str, default="auto", choices=["auto", "cuda", "cpu"])
parser.add_argument("--port", type=int, default=5052)
args = parser.parse_args()

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
APP_ROOT = os.environ.get("FERIDE_ROOT") or os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
BUNDLED_BASE_DIR = os.path.join(APP_ROOT, "models", "whisper", "base")
BUNDLED_SMALL_DIR = os.path.join(APP_ROOT, "models", "whisper", "small")
BUNDLED_TURBO_DIR = os.path.join(APP_ROOT, "models", "whisper", "large-v3-turbo")
# CTranslate2 varsayılan olarak 4 iş parçacığı kullanır; çok çekirdekli işlemcilerde biraz artır.
CPU_THREADS = int(os.environ.get("FERIDE_STT_THREADS", "0")) or max(4, min(16, (os.cpu_count() or 8) // 2))
BEAM_SIZE = int(os.environ.get("FERIDE_STT_BEAM", "5"))
# "auto" kipinde hızlı modelin sonucu bu ortalama log-olasılığın altındaysa doğru modelle yeniden çevrilir.
AUTO_LOGPROB = float(os.environ.get("FERIDE_STT_AUTO_LOGPROB", "-0.28"))

_model_lock = threading.Lock()
_backend = None
_model_label = "initializing"
_model = None
# İkinci, daha doğru (ve daha yavaş) model: large-v3-turbo. "auto" ve "accurate" kiplerinde kullanılır.
_accurate = None
_accurate_label = None


def _find_cached_hf_snapshot(repo_folder_name: str):
    """~/.feride/cache/whisper altında indirilmiş faster-whisper snapshot dizinini bulur."""
    snaps_root = os.path.join(CACHE_DIR, repo_folder_name, "snapshots")
    if not os.path.isdir(snaps_root):
        return None
    for entry in sorted(os.listdir(snaps_root), reverse=True):
        candidate = os.path.join(snaps_root, entry)
        if os.path.isfile(os.path.join(candidate, "model.bin")):
            return candidate
    return None


def _background_upgrade_to_small():
    """Gömülü base ile anında açıldıktan sonra internet varsa small modelini önbelleğe alıp yükseltir."""
    global _model, _model_label
    try:
        from faster_whisper import WhisperModel

        log.info("Arka planda faster-whisper 'small' modeli kontrol ediliyor/indiriliyor...")
        upgraded = WhisperModel("small", device="cpu", compute_type="int8", download_root=CACHE_DIR)
        with _model_lock:
            _model = upgraded
            _model_label = "faster-whisper-small"
        log.info("✅ STT motoru arka planda 'faster-whisper-small' modeline yükseltildi!")
    except Exception as e:
        log.info("Arka plan 'small' yükseltmesi atlandı (gömülü base aktif kalmaya devam ediyor): %s", e)


def _init_model():
    global _backend, _model, _model_label

    # 1. İsteğe bağlı: openai-whisper + torch (özel GPU ses ortamı kuruluysa)
    if os.environ.get("FERIDE_FORCE_FASTER_WHISPER") != "1":
        try:
            import torch
            import whisper

            dev = ("cuda" if torch.cuda.is_available() else "cpu") if args.device == "auto" else args.device
            log.info("openai-whisper turbo yükleniyor (device=%s)...", dev)
            _model = whisper.load_model("turbo", device=dev)
            _backend = "openai-whisper"
            _model_label = f"whisper-turbo-{dev}"
            log.info("✅ openai-whisper turbo hazır (%s)", dev)
            return
        except Exception:
            pass

    # 2. Yerleşik hızlı motor: faster-whisper (CTranslate2 int8 — tüm işletim sistemlerinde çalışır)
    from faster_whisper import WhisperModel

    global _accurate, _accurate_label

    def has(path):
        return os.path.isfile(os.path.join(path, "model.bin"))

    def load(path, label):
        log.info("faster-whisper-%s yükleniyor (%d iş parçacığı): %s", label, CPU_THREADS, path)
        m = WhisperModel(path, device="cpu", compute_type="int8", cpu_threads=CPU_THREADS)
        log.info("✅ faster-whisper (%s) hazır!", label)
        return m

    # Hızlı model: small (~1 sn). Doğru model: large-v3-turbo (~3 sn, Türkçede belirgin biçimde daha iyi).
    small = BUNDLED_SMALL_DIR if has(BUNDLED_SMALL_DIR) else _find_cached_hf_snapshot("models--Systran--faster-whisper-small")
    if has(BUNDLED_TURBO_DIR):
        _accurate = load(BUNDLED_TURBO_DIR, "large-v3-turbo")
        _accurate_label = "faster-whisper-large-v3-turbo"
    if small:
        _model = load(small, "small")
        _backend = "faster-whisper"
        _model_label = "faster-whisper-small"
        return
    if _accurate is not None:
        _model, _backend, _model_label = _accurate, "faster-whisper", _accurate_label
        return

    if os.path.isfile(os.path.join(BUNDLED_BASE_DIR, "model.bin")):
        log.info("Gömülü çevrimdışı faster-whisper-base yükleniyor: %s", BUNDLED_BASE_DIR)
        _model = WhisperModel(BUNDLED_BASE_DIR, device="cpu", compute_type="int8", cpu_threads=CPU_THREADS)
        _backend = "faster-whisper"
        _model_label = "faster-whisper-base (embedded)"
        log.info("✅ Gömülü faster-whisper (base) 0 internetle anında hazır!")
        threading.Thread(target=_background_upgrade_to_small, daemon=True).start()
        return

    preferred = os.environ.get("FERIDE_WHISPER_MODEL", "base")
    log.info("faster-whisper (%s) indiriliyor/yükleniyor...", preferred)
    _model = WhisperModel(preferred, device="cpu", compute_type="int8", download_root=CACHE_DIR)
    _backend = "faster-whisper"
    _model_label = f"faster-whisper-{preferred}"
    log.info("✅ faster-whisper (%s) hazır!", preferred)


_init_model()


def decode_audio_bytes_to_16k_float32(audio_bytes: bytes) -> np.ndarray:
    """
    Gelen ses baytlarını PyAV kullanmadan 16000 Hz mono float32 NumPy dizisine dönüştürür.
    1) Önce ffmpeg ile tüm ses kodeklerini (WAV/MP3/M4A/WebM/OGG, her örnekleme hızı) çözer.
    2) Sistemde ffmpeg yoksa standart Python `wave` modülü + doğrusal yeniden örnekleme kullanır.
    """
    if not audio_bytes or len(audio_bytes) < 64:
        return np.zeros(0, dtype=np.float32)

    ffmpeg_bin = shutil.which("ffmpeg")
    if ffmpeg_bin:
        fd, tmp_in = tempfile.mkstemp(suffix=".audio", prefix="feride_stt_in_")
        os.close(fd)
        try:
            with open(tmp_in, "wb") as f:
                f.write(audio_bytes)
            proc = subprocess.run(
                [
                    ffmpeg_bin,
                    "-nostdin",
                    "-threads",
                    "0",
                    "-i",
                    tmp_in,
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
                timeout=30,
            )
            if proc.returncode == 0 and len(proc.stdout) > 0:
                pcm = np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0
                return pcm
        except Exception as e:
            log.warning("ffmpeg ses çözme uyarısı, wave yedeğine geçiliyor: %s", e)
        finally:
            try:
                os.remove(tmp_in)
            except Exception:
                pass

    # Saf Python WAV yedeği (ffmpeg kurulu olmayan Windows/macOS/Linux sistemler için)
    with wave.open(io.BytesIO(audio_bytes), "rb") as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        raw_frames = wf.readframes(wf.getnframes())

    if sampwidth == 2:
        samples = np.frombuffer(raw_frames, dtype=np.int16).astype(np.float32) / 32768.0
    elif sampwidth == 4:
        samples = np.frombuffer(raw_frames, dtype=np.int32).astype(np.float32) / 2147483648.0
    elif sampwidth == 1:
        samples = (np.frombuffer(raw_frames, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        raise ValueError(f"Desteklenmeyen WAV örnek genişliği: {sampwidth}")

    if n_channels > 1:
        samples = samples.reshape(-1, n_channels).mean(axis=1)

    if framerate != 16000 and len(samples) > 0:
        duration = len(samples) / float(framerate)
        target_len = max(1, int(round(duration * 16000)))
        old_idx = np.linspace(0.0, 1.0, num=len(samples), endpoint=False)
        new_idx = np.linspace(0.0, 1.0, num=target_len, endpoint=False)
        samples = np.interp(new_idx, old_idx, samples).astype(np.float32)

    return samples.astype(np.float32)


HALLUCINATION_RE = re.compile(
    r"(?i)\b(altyazı m\.k\.?|altyazı|m\.k\.?|amara\.org|abone olmayı unutmayın|"
    r"izlediğiniz için teşekkürler|çeviri[:\s]*|mbc|altyazı ekleyen[:\s]*)\b"
)


# Whisper'a bağlam ipucu: asistanın adını doğru yazması için.
INITIAL_PROMPT = "Bu Türkçe bir konuşmadır. Feride bir yapay zeka asistanıdır. Feride, evet, hayır, tamam."


def remove_dc(x: np.ndarray, win: int = 801) -> np.ndarray:
    """DC kaymasını ve ~20 Hz altı uğultuyu kaldırır.

    Bazı dahili mikrofonlar (örn. AMD SoundWire) sinyale sabit bir DC ofseti
    ekler; bu hem sessizlik tespitini hem de normalizasyonu bozar.
    """
    if len(x) == 0:
        return x
    x = x - float(np.mean(x))
    if len(x) > win * 2:
        kernel = np.ones(win, dtype=np.float32) / win
        x = x - np.convolve(x, kernel, mode="same")
    return x.astype(np.float32)


def _faster(model, audio_f32: np.ndarray, lang: str, vad: bool):
    """faster-whisper ile çevirir; (metin, ortalama log-olasılık) döndürür."""
    kwargs = dict(
        language=lang or "tr",
        beam_size=BEAM_SIZE,
        condition_on_previous_text=False,
        initial_prompt=INITIAL_PROMPT,
        without_timestamps=True,
    )
    try:
        # Arayüz konuşmayı zaten ayırdıysa (canlı sohbet) Silero VAD kapalı: kısık ya da alışılmadık
        # mikrofonlarda kaydın tamamını "konuşma yok" diye atabiliyordu.
        segments, _ = model.transcribe(audio_f32, vad_filter=vad,
                                       vad_parameters={"min_silence_duration_ms": 500, "threshold": 0.35}, **kwargs)
        seg_list = list(segments)
    except Exception as vad_err:
        log.warning("VAD filtresi atlandı, doğrudan deşifre uygulanıyor: %s", vad_err)
        segments, _ = model.transcribe(audio_f32, vad_filter=False, **kwargs)
        seg_list = list(segments)
    # Konuşma arayüzde algılandıysa (vad=False) "konuşma yok" olasılığına daha az güven.
    keep = [g for g in seg_list if getattr(g, "no_speech_prob", 0.0) < (0.70 if vad else 0.90)]
    text = " ".join(g.text.strip() for g in keep)
    logprob = float(np.mean([g.avg_logprob for g in keep])) if keep else -9.0
    return text, logprob


def _clean(text: str) -> str:
    text = HALLUCINATION_RE.sub("", text.strip())
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"^[\.,\?!\s]+", "", text)


def transcribe_audio_bytes(audio_bytes: bytes, lang: str = "tr", vad: bool = True, quality: str = "auto") -> str:
    raw = decode_audio_bytes_to_16k_float32(audio_bytes)
    if len(raw) == 0:
        return ""
    # Tanı: mikrofon sorunlarını (DC kayması, çok kısık ses) günlükten görebilmek için.
    dc = float(np.mean(raw))
    rms = float(np.sqrt(np.mean((raw - dc) ** 2))) + 1e-9
    log.info("Giriş: %.2f sn, tepe=%.3f, RMS=%.1f dBFS, DC=%.3f, VAD=%s, kip=%s",
             len(raw) / 16000, float(np.max(np.abs(raw))), 20 * np.log10(rms), dc, "açık" if vad else "kapalı", quality)
    audio_f32 = remove_dc(raw)
    if len(audio_f32) < 1600:  # < 0.1 saniye
        return ""

    # Tamamen sessiz kayıtları filtrele
    peak = float(np.max(np.abs(audio_f32)))
    if peak < 0.003:
        log.info("Ses tepe genliği çok düşük (peak=%.5f), sessizlik olarak atlandı.", peak)
        return ""

    # Kısık kayıtları duyulur düzeye getir
    if peak < 0.3:
        gain = min(20.0, 0.6 / peak)
        audio_f32 = np.clip(audio_f32 * gain, -1.0, 1.0)

    with _model_lock:
        fast, accurate, backend = _model, _accurate, _backend

    if backend == "openai-whisper":
        result = fast.transcribe(audio_f32, language=lang or "tr", task="transcribe",
                                 condition_on_previous_text=False, initial_prompt=INITIAL_PROMPT)
        text = " ".join(g.get("text", "") for g in result.get("segments", []) if g.get("no_speech_prob", 0.0) < 0.65)
        return _clean(text)

    import time as _t
    t0 = _t.time()
    if quality == "accurate" and accurate is not None:
        text, lp = _faster(accurate, audio_f32, lang, vad)
        used = "turbo"
    else:
        text, lp = _faster(fast, audio_f32, lang, vad)
        used = "hızlı"
        # Belirsiz ya da boş sonuç: doğru modelle bir kez daha dene.
        if quality == "auto" and accurate is not None and accurate is not fast and (lp < AUTO_LOGPROB or not _clean(text)):
            log.info("Hızlı model emin değil (logprob=%.3f): %r — turbo ile yeniden çevriliyor", lp, text)
            text, lp = _faster(accurate, audio_f32, lang, vad)
            used = "hızlı→turbo"
    log.info("Çeviri: %s, %.2f sn, logprob=%.3f", used, _t.time() - t0, lp)
    return _clean(text)


class STTRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/health"):
            body = json.dumps(
                {"status": "ok", "backend": _backend, "model": _model_label}
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path.startswith("/transcribe"):
            try:
                content_length = int(self.headers.get("Content-Length", 0))
                raw_body = self.rfile.read(content_length)
                ctype = self.headers.get("Content-Type", "")
                audio_data = raw_body
                if "multipart/form-data" in ctype.lower() and "boundary=" in ctype:
                    boundary = ctype.split("boundary=", 1)[1].strip().strip('"').encode("utf-8", errors="ignore")
                    for part in raw_body.split(b"--" + boundary):
                        if b"\r\n\r\n" in part and b"Content-Disposition:" in part:
                            _, payload_part = part.split(b"\r\n\r\n", 1)
                            if payload_part.endswith(b"\r\n"):
                                payload_part = payload_part[:-2]
                            if len(payload_part) > 64:
                                audio_data = payload_part
                                break
                lang = self.headers.get("X-Language", "tr").strip() or "tr"
                vad = self.headers.get("X-Vad", "on").strip().lower() != "off"
                quality = self.headers.get("X-Quality", "auto").strip().lower()
                text = transcribe_audio_bytes(audio_data, lang=lang, vad=vad, quality=quality)
                log.info("Deşifre tamamlandı (%d bayt) -> %r", len(audio_data), text)
                payload = json.dumps({"text": text}, ensure_ascii=False).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except Exception as e:
                log.exception("Deşifre hatası")
                payload = json.dumps({"error": str(e)}, ensure_ascii=False).encode("utf-8")
                self.send_response(500)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", args.port), STTRequestHandler)
    log.info("STT Sunucusu başlatıldı: http://127.0.0.1:%d (Motor: %s / %s)", args.port, _backend, _model_label)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
