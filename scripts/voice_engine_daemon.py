#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE Canlı Ses Köprüsü (VAD) — ws://127.0.0.1:5051
=====================================================
İstemci 16 kHz mono int16 PCM gönderir. Bu servis konuşmanın başını ve sonunu
algılar, biten konuşmayı STT sunucusuna (5052) verir ve şu mesajları yollar:

  {"type": "level", "level": 0..1, "speaking": bool}   ~10/sn (arayüz için)
  {"type": "speech_start"}
  {"type": "speech_end"}
  {"type": "transcript", "event": "transcription", "text": "..."}

Algılama, ham enerji yerine 300–3400 Hz konuşma bandındaki enerjiye bakar.
Böylece mikrofonların ürettiği DC kayması (bazı dahili AMD/Intel mikrofonlarda
±0.2 düzeyinde) ve düşük frekanslı uğultu VAD'ı yanıltmaz. Gürültü tabanı
sürekli uyarlanır; bu yüzden ortam sessizliği hiçbir zaman "konuşma" sayılmaz.
"""

import asyncio
import io
import json
import time
import urllib.request
import wave

import numpy as np
import websockets

SAMPLE_RATE = 16000
FRAME = 512                       # 32 ms
FRAME_SEC = FRAME / SAMPLE_RATE
SILENCE_TO_END = 0.9              # bu kadar sessizlik konuşmayı bitirir (sn)
MIN_SPEECH = 0.30                 # bundan kısa sesler (tık, öksürük) yok sayılır
MAX_UTTERANCE = 25.0              # en uzun tek konuşma (sn) — asla takılı kalmaz
PRE_ROLL_FRAMES = 10              # ilk heceyi kaçırmamak için ~320 ms geri sarma
START_FRAMES = 3                  # konuşma sayılması için art arda çerçeve
ABS_MIN_LEVEL = 0.0025            # mutlak alt eşik (konuşma bandı RMS)

_freqs = np.fft.rfftfreq(FRAME, 1.0 / SAMPLE_RATE)
_band = (_freqs >= 300) & (_freqs <= 3400)
_window = np.hanning(FRAME).astype(np.float32)


def band_level(frame_f32: np.ndarray) -> float:
    """Konuşma bandındaki RMS benzeri seviye (DC ve uğultudan etkilenmez)."""
    x = (frame_f32 - frame_f32.mean()) * _window
    spec = np.abs(np.fft.rfft(x)) / (FRAME / 2)
    return float(np.sqrt(np.mean(spec[_band] ** 2)) * 4.0)


def remove_dc(x: np.ndarray, win: int = 801) -> np.ndarray:
    x = x - float(np.mean(x))
    if len(x) > win * 2:
        x = x - np.convolve(x, np.ones(win, dtype=np.float32) / win, mode="same")
    return x


def transcribe(pcm_int16: np.ndarray) -> str:
    audio = remove_dc(pcm_int16.astype(np.float32) / 32768.0)
    peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
    if 0.0 < peak < 0.3:  # kısık mikrofonu güvenle yükselt
        audio = audio * min(8.0, 0.5 / peak)
    pcm = (np.clip(audio, -1, 1) * 32767).astype(np.int16)

    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm.tobytes())
    req = urllib.request.Request(
        "http://127.0.0.1:5052/transcribe",
        data=buf.getvalue(),
        headers={"Content-Type": "application/octet-stream"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8")).get("text", "").strip()
    except Exception as e:  # noqa: BLE001
        print(f"STT hatası: {e}", flush=True)
        return ""


class Detector:
    def __init__(self):
        self.noise = None          # uyarlanan gürültü tabanı
        self.speaking = False
        self.voiced_run = 0
        self.silence = 0.0
        self.speech_time = 0.0
        self.utterance: list[np.ndarray] = []
        self.pre_roll: list[np.ndarray] = []

    def threshold(self) -> float:
        base = self.noise if self.noise is not None else ABS_MIN_LEVEL
        return max(ABS_MIN_LEVEL, base * 3.0)

    def feed(self, frame_i16: np.ndarray):
        """Bir çerçeve işler. Dönüş: (olay|None, seviye, biten_konuşma|None)."""
        lvl = band_level(frame_i16.astype(np.float32) / 32768.0)
        if self.noise is None:
            self.noise = lvl
        voiced = lvl > self.threshold()
        event, finished = None, None

        if not self.speaking:
            # Sessizken gürültü tabanını takip et (hızlı düş, yavaş yüksel)
            rate = 0.2 if lvl < self.noise else 0.02
            self.noise = (1 - rate) * self.noise + rate * lvl
            self.pre_roll.append(frame_i16)
            if len(self.pre_roll) > PRE_ROLL_FRAMES:
                self.pre_roll.pop(0)
            self.voiced_run = self.voiced_run + 1 if voiced else 0
            if self.voiced_run >= START_FRAMES:
                self.speaking = True
                self.utterance = list(self.pre_roll)
                self.pre_roll.clear()
                self.silence = 0.0
                self.speech_time = self.voiced_run * FRAME_SEC
                event = "speech_start"
        else:
            self.utterance.append(frame_i16)
            if voiced:
                self.silence = 0.0
                self.speech_time += FRAME_SEC
            else:
                self.silence += FRAME_SEC
            total = len(self.utterance) * FRAME_SEC
            if self.silence >= SILENCE_TO_END or total >= MAX_UTTERANCE:
                self.speaking = False
                self.voiced_run = 0
                event = "speech_end"
                if self.speech_time >= MIN_SPEECH:
                    finished = np.concatenate(self.utterance)
                self.utterance = []
        return event, lvl, finished

    def reset(self):
        noise = self.noise
        self.__init__()
        self.noise = noise


async def handle_client(ws):
    print("Canlı oturum istemcisi bağlandı.", flush=True)
    det = Detector()
    pending = bytearray()
    last_level_sent = 0.0
    try:
        async for message in ws:
            if isinstance(message, str):
                try:
                    cmd = json.loads(message).get("command")
                except Exception:  # noqa: BLE001
                    cmd = message.strip()
                if cmd == "stop":
                    break
                if cmd == "reset":
                    det.reset()
                    pending.clear()
                continue

            pending.extend(message)
            while len(pending) >= FRAME * 2:
                frame = np.frombuffer(bytes(pending[: FRAME * 2]), dtype=np.int16)
                del pending[: FRAME * 2]
                event, lvl, finished = det.feed(frame)

                now = time.monotonic()
                if now - last_level_sent >= 0.1:
                    last_level_sent = now
                    norm = float(min(1.0, lvl / max(det.threshold() * 4, 1e-6)))
                    await ws.send(json.dumps({"type": "level", "level": round(norm, 3), "speaking": det.speaking}))

                if event:
                    await ws.send(json.dumps({"type": event, "event": event}))
                if finished is not None:
                    text = await asyncio.get_running_loop().run_in_executor(None, transcribe, finished)
                    if text:
                        print(f"Deşifre: {text}", flush=True)
                        await ws.send(json.dumps(
                            {"type": "transcript", "event": "transcription", "text": text}, ensure_ascii=False))
    except websockets.exceptions.ConnectionClosed:
        pass


async def main():
    port = int(__import__("os").environ.get("FERIDE_VAD_PORT", "5051"))
    print(f"FerIDE canlı ses köprüsü: ws://127.0.0.1:{port}", flush=True)
    async with websockets.serve(handle_client, "127.0.0.1", port, max_size=None):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
