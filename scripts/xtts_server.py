"""
FerIDE XTTS Sunucusu (GPU + Metin Temizleme)
=============================================
Tamamen lokal, GPU hızlandırmalı XTTS v2 TTS sunucusu.
Doğal Türk kadın sesi - feride_reference.wav referansı ile.
Gelen metinden JSON/kod/markdown otomatik temizlenir.
"""

import os
import sys
import re
import argparse
import tempfile
from flask import Flask, request, send_file
import torch
from TTS.api import TTS

parser = argparse.ArgumentParser(description="FerIDE XTTS Server")
parser.add_argument('--device', type=str, default='auto', choices=['auto', 'cuda', 'cpu'],
                    help='Cihaz (auto: GPU varsa GPU, yoksa CPU — v5.3.1 dağıtımdan bağımsızlık)')
args = parser.parse_args()

# v5.3.1: 'auto' → GPU yoksa CPU'ya düş (ROCm kurulmamış dağıtımlar için)
if args.device == 'auto':
    import torch as _torch
    args.device = 'cuda' if _torch.cuda.is_available() else 'cpu'
    print(f"Cihaz otomatik seçildi: {args.device}")

os.environ["COQUI_TOS_AGREED"] = "1"
os.environ["HSA_OVERRIDE_GFX_VERSION"] = "11.0.0"

app = Flask(__name__)

# ROCm/HIP için MIOpen exhaustive aramasını kapatıyoruz
torch.backends.cudnn.benchmark = False
torch.backends.cudnn.deterministic = True

print(f"XTTS Server başlatılıyor... (Cihaz: {args.device})")
try:
    tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(args.device)
    print(f"✅ XTTS Modeli başarıyla yüklendi! (Cihaz: {args.device})")
except Exception as e:
    print("XTTS Yüklenirken Hata:", e)
    sys.exit(1)


def clean_text_for_speech(text: str) -> str:
    """LLM çıktısından konuşmaya uygun olmayan her şeyi temizler."""
    if not text:
        return ""

    text = re.sub(r'\{[^}]*\}', '', text)
    text = re.sub(r'\[[^\]]*\]', '', text)
    text = re.sub(r'```[\s\S]*?```', '', text)
    text = re.sub(r'`[^`]+`', '', text)
    text = re.sub(r'\*+', '', text)
    text = re.sub(r'#+\s*', '', text)
    text = re.sub(r'[-]\s+', '', text)
    text = re.sub(r'https?://\S+', '', text)
    text = re.sub(r'[<>{}()\[\]|\\/@#$%^&=+~_]', ' ', text)
    text = re.sub(r'\s+', ' ', text).strip()
    text = text.replace('İ', 'i').replace('I', 'ı')

    if len(text) < 2:
        return ""

    return text


@app.route('/tts', methods=['POST'])
def generate_tts():
    data = request.json
    raw_text = data.get('text', '').strip()
    if not raw_text:
        return {"error": "Text is empty"}, 400

    text = clean_text_for_speech(raw_text)

    if not text:
        return {"error": "Text contained only non-speech content"}, 400

    out_path = os.path.join(tempfile.gettempdir(), "feride_xtts_server_out.wav")
    print(f"🔊 Ses üretiliyor: {text}")
    try:
        # Kendi assets klasörümüzdeki referans ses dosyasını kullanıyoruz (Portable)
        script_dir = os.path.dirname(os.path.abspath(__file__))
        ref_path = os.path.join(script_dir, "..", "assets", "feride_reference.wav")
        
        tts.tts_to_file(
            text=text,
            speaker_wav=ref_path,
            language="tr",
            file_path=out_path
        )
        return send_file(out_path, mimetype="audio/wav")
    except Exception as e:
        print(f"❌ Ses üretimi hatası: {e}")
        return {"error": str(e)}, 500

if __name__ == '__main__':
    port = 5050
    print(f"XTTS Sunucusu başlatıldı. Port: {port} - Cihaz: {args.device}")
    app.run(host='127.0.0.1', port=port)
