#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE Voice Engine Daemon (v5.3.4 — Linux / Windows / macOS)
=============================================================
Silero VAD (varsa) veya adaptif NumPy RMS VAD + STT Sunucusu (Port 5052) köprüsü.
Canlı Ses Oturumu (ws://127.0.0.1:5051) için konuşma başlangıç/bitişini algılar
ve `{"type": "transcript", "event": "transcription", "text": ...}` gönderir.
"""

import asyncio
import io
import json
import os
import urllib.request
import wave
from urllib.error import URLError

import numpy as np
import websockets

HOME_DIR = os.path.expanduser("~")
TORCH_HUB_DIR = os.path.join(HOME_DIR, ".cache", "torch_hub_feride")
SAMPLE_RATE = 16000
VAD_THRESHOLD = 0.42
SILENCE_DURATION = 1.25

_use_torch_vad = False
_vad_model = None

try:
    import torch

    os.makedirs(TORCH_HUB_DIR, exist_ok=True)
    torch.hub.set_dir(TORCH_HUB_DIR)
    _vad_model, _ = torch.hub.load(
        repo_or_dir="snakers4/silero-vad",
        model="silero_vad",
        force_reload=False,
        onnx=False,
    )
    _use_torch_vad = True
    print("✅ Silero VAD (PyTorch) yüklendi.")
except Exception:
    print("ℹ️ Yerleşik adaptif NumPy VAD motoru aktif (PyTorch gerektirmez).")


def detect_speech_prob(audio_float32: np.ndarray, noise_floor: float = 0.005) -> float:
    if _use_torch_vad and _vad_model is not None:
        import torch

        if len(audio_float32) == 512:
            tensor = torch.from_numpy(audio_float32)
            return float(_vad_model(tensor, SAMPLE_RATE).item())
    if len(audio_float32) == 0:
        return 0.0
    rms = float(np.sqrt(np.mean(np.square(audio_float32))))
    effective = max(0.0, rms - noise_floor)
    return min(1.0, effective * 28.0)


def send_pcm_to_stt_server(pcm_int16: np.ndarray) -> str:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm_int16.tobytes())
    audio_data = buf.getvalue()

    req = urllib.request.Request(
        "http://127.0.0.1:5052/transcribe",
        data=audio_data,
        headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": str(len(audio_data)),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=40) as response:
            res_data = response.read().decode("utf-8")
            return json.loads(res_data).get("text", "")
    except URLError as e:
        print(f"STT Sunucusuna ulaşılamadı: {e}")
        return ""
    except Exception as e:
        print(f"STT Hata: {e}")
        return ""


async def handle_client(websocket):
    print("İstemci bağlandı (Canlı Ses Oturumu). Dinleniyor...")
    full_audio_buffer = []
    pre_roll_buffer = []
    is_speaking = False
    silence_frames = 0
    chunk_duration = 512 / SAMPLE_RATE
    max_silence_frames = int(SILENCE_DURATION / chunk_duration)
    byte_buffer = bytearray()
    noise_floor = 0.004

    try:
        async for message in websocket:
            if isinstance(message, bytes):
                byte_buffer.extend(message)
                while len(byte_buffer) >= 1024:
                    chunk_bytes = bytes(byte_buffer[:1024])
                    del byte_buffer[:1024]

                    audio_int16 = np.frombuffer(chunk_bytes, dtype=np.int16)
                    audio_float32 = audio_int16.astype(np.float32) / 32768.0
                    rms = float(np.sqrt(np.mean(np.square(audio_float32))))
                    speech_prob = detect_speech_prob(audio_float32, noise_floor=noise_floor)

                    if speech_prob > VAD_THRESHOLD:
                        if not is_speaking:
                            is_speaking = True
                            # Kelimenin ilk hecesini kaçırmamak için son 8 paketi (~250ms) başa ekle
                            full_audio_buffer.extend(pre_roll_buffer)
                            pre_roll_buffer.clear()
                            await websocket.send(json.dumps({"type": "speech_start", "event": "speech_start"}))
                        silence_frames = 0
                        full_audio_buffer.append(audio_int16)
                    else:
                        if not is_speaking:
                            noise_floor = 0.97 * noise_floor + 0.03 * min(rms, 0.025)
                            pre_roll_buffer.append(audio_int16)
                            if len(pre_roll_buffer) > 8:
                                pre_roll_buffer.pop(0)
                        else:
                            full_audio_buffer.append(audio_int16)
                            silence_frames += 1
                            if silence_frames > max_silence_frames:
                                is_speaking = False
                                silence_frames = 0
                                await websocket.send(json.dumps({"type": "speech_end", "event": "speech_end"}))

                                combined = np.concatenate(full_audio_buffer, axis=0)
                                full_audio_buffer = []

                                loop = asyncio.get_running_loop()
                                text = await loop.run_in_executor(None, send_pcm_to_stt_server, combined)
                                if text and text.strip():
                                    clean = text.strip()
                                    print(f"Canlı Deşifre: {clean}")
                                    await websocket.send(
                                        json.dumps(
                                            {
                                                "type": "transcript",
                                                "event": "transcription",
                                                "text": clean,
                                            },
                                            ensure_ascii=False,
                                        )
                                    )
            elif isinstance(message, str):
                try:
                    data = json.loads(message)
                    cmd = data.get("command")
                    if cmd == "stop":
                        break
                    elif cmd == "reset":
                        full_audio_buffer = []
                        pre_roll_buffer = []
                        is_speaking = False
                        silence_frames = 0
                        byte_buffer.clear()
                except Exception:
                    pass
    except websockets.exceptions.ConnectionClosed:
        pass


async def main():
    port = 5051
    print(f"FerIDE Voice Engine Daemon başlatıldı: ws://127.0.0.1:{port}")
    async with websockets.serve(handle_client, "127.0.0.1", port):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
