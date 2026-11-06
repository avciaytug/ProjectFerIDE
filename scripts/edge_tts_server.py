"""
FerIDE Edge-TTS Sunucusu
========================
XTTS'in yerine geçen, çok hızlı (<1s) ve doğal Türkçe kadın sesi üreten TTS sunucusu.
Microsoft Edge Neural TTS motoru kullanır (tr-TR-EmelNeural).
"""

import asyncio
import re
import os

from flask import Flask, request, send_file
import edge_tts

app = Flask(__name__)

VOICE = "tr-TR-EmelNeural"  # Doğal Türk kadın sesi

def clean_text_for_speech(text: str) -> str:
    """LLM çıktısından konuşmaya uygun olmayan her şeyi temizler."""
    if not text:
        return ""

    # 1. JSON blokları temizle: {"name": ...} veya [{"key": ...}]
    text = re.sub(r'\{[^}]*\}', '', text)
    text = re.sub(r'\[[^\]]*\]', '', text)

    # 2. Kod blokları temizle: ```...```
    text = re.sub(r'```[\s\S]*?```', '', text)
    text = re.sub(r'`[^`]+`', '', text)

    # 3. Markdown işaretlerini temizle
    text = re.sub(r'\*+', '', text)       # **bold**, *italic*
    text = re.sub(r'#+\s*', '', text)     # ### başlıklar
    text = re.sub(r'[-*]\s+', '', text)   # - liste öğeleri

    # 4. URL'leri temizle
    text = re.sub(r'https?://\S+', '', text)

    # 5. Özel karakterleri temizle
    text = re.sub(r'[<>{}()\[\]|\\/@#$%^&=+~]', ' ', text)

    # 6. Çoklu boşlukları ve satır sonlarını tek boşluğa indir
    text = re.sub(r'\s+', ' ', text).strip()

    # 7. Çok kısa veya boş kalan metni kontrol et
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
        # Metin tamamen temizlendiyse (sadece kod/JSON vardı), sessiz WAV döndürme yerine boş hata
        return {"error": "Text contained only non-speech content"}, 400

    print(f"🔊 Edge-TTS üretiyor: {text}")

    out_path = "/tmp/feride_edge_tts_out.mp3"

    try:
        # edge-tts async çalışıyor, Flask sync olduğu için asyncio.run kullanıyoruz
        asyncio.run(_generate(text, out_path))
        return send_file(out_path, mimetype="audio/mpeg")
    except Exception as e:
        print(f"❌ Edge-TTS hatası: {e}")
        return {"error": str(e)}, 500


async def _generate(text: str, out_path: str):
    """Edge-TTS ile ses dosyası üretir."""
    communicate = edge_tts.Communicate(text, VOICE)
    await communicate.save(out_path)


if __name__ == '__main__':
    print(f"✅ Edge-TTS Sunucusu başlatılıyor (Ses: {VOICE})...")
    print(f"   Port: 5050")
    app.run(host='127.0.0.1', port=5050)
