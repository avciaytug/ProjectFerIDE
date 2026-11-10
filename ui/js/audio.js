// Ses yardımcıları: mikrofon (ham PCM), WAV kodlama, sıralı ses çalar.
// Kayıtlar 16 kHz mono WAV olarak gönderilir; böylece STT sunucusu ffmpeg olmadan da çözebilir.

export class Mic {
  constructor() {
    this.stream = null;
    this.ctx = null;
    this.node = null;
    this.rate = 48000;
  }

  /** Mikrofonu açar; her ~20 ms'de `onFrame(Float32Array)` çağrılır. */
  async start(onFrame) {
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
    });
    this.ctx = new AudioContext();
    this.rate = this.ctx.sampleRate;
    const src = this.ctx.createMediaStreamSource(this.stream);
    const sink = this.ctx.createGain();
    sink.gain.value = 0; // grafiğin işlenmesi için hedefe bağlı ama sessiz
    sink.connect(this.ctx.destination);
    try {
      await this.ctx.audioWorklet.addModule('js/pcm-worklet.js');
      this.node = new AudioWorkletNode(this.ctx, 'feride-pcm-tap');
      this.node.port.onmessage = (e) => onFrame(e.data);
    } catch {
      // Eski WebView: ScriptProcessor yedeği.
      this.node = this.ctx.createScriptProcessor(1024, 1, 1);
      this.node.onaudioprocess = (e) => onFrame(new Float32Array(e.inputBuffer.getChannelData(0)));
    }
    // 80 Hz yüksek geçiren süzgeç: bazı dahili mikrofonların (ör. AMD SoundWire) eklediği DC kaymasını
    // ve uğultuyu siler. Aksi halde ses düzeyi hiç düşmez, konuşmanın bittiği algılanamaz ve Whisper bozulur.
    const hp = this.ctx.createBiquadFilter();
    hp.type = 'highpass';
    hp.frequency.value = 80;
    hp.Q.value = 0.707;
    src.connect(hp);
    hp.connect(this.node);
    this.node.connect(sink);
    if (this.ctx.state === 'suspended') await this.ctx.resume();
  }

  setMuted(m) {
    this.stream?.getAudioTracks().forEach((t) => { t.enabled = !m; });
  }

  stop() {
    this.stream?.getTracks().forEach((t) => t.stop());
    try { this.node?.disconnect(); } catch { /* */ }
    this.ctx?.close().catch(() => {});
    this.stream = null;
    this.ctx = null;
    this.node = null;
  }
}

/** Parçanın ses düzeyi (dBFS, sessizlik ≈ -100). */
export function levelDb(frame) {
  let sum = 0;
  for (let i = 0; i < frame.length; i++) sum += frame[i] * frame[i];
  const rms = Math.sqrt(sum / Math.max(1, frame.length));
  return rms > 0 ? 20 * Math.log10(rms) : -100;
}

/** Float32 parçaları 16 kHz mono 16-bit WAV'a çevirir; kısık kayıtları duyulur düzeye getirir. */
export function encodeWav(chunks, srcRate, dstRate = 16000) {
  let total = 0;
  for (const c of chunks) total += c.length;
  const src = new Float32Array(total);
  let off = 0;
  for (const c of chunks) { src.set(c, off); off += c.length; }
  // Kalan DC'yi çıkar ve tepe düzeyini ~-3 dBFS'e getir (en fazla 30 kat; gürültüyü aşırı büyütmemek için).
  let mean = 0;
  for (let i = 0; i < src.length; i++) mean += src[i];
  mean /= Math.max(1, src.length);
  let peak = 0;
  for (let i = 0; i < src.length; i++) { src[i] -= mean; const a = Math.abs(src[i]); if (a > peak) peak = a; }
  const gain = peak > 1e-4 ? Math.min(30, 0.7 / peak) : 1;
  if (gain > 1.05 || gain < 0.95) for (let i = 0; i < src.length; i++) src[i] *= gain;
  // Kutu filtresiyle yeniden örnekleme (örtüşmeyi azaltır; konuşma için yeterli).
  const ratio = srcRate / dstRate;
  const outLen = Math.floor(src.length / ratio);
  const pcm = new Int16Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const a = Math.floor(i * ratio);
    const b = Math.max(a + 1, Math.floor((i + 1) * ratio));
    let s = 0;
    for (let j = a; j < b && j < src.length; j++) s += src[j];
    const v = Math.max(-1, Math.min(1, s / (b - a)));
    pcm[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
  }
  const buf = new ArrayBuffer(44 + pcm.length * 2);
  const dv = new DataView(buf);
  const str = (o, s) => { for (let i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i)); };
  str(0, 'RIFF');
  dv.setUint32(4, 36 + pcm.length * 2, true);
  str(8, 'WAVE');
  str(12, 'fmt ');
  dv.setUint32(16, 16, true);
  dv.setUint16(20, 1, true); // PCM
  dv.setUint16(22, 1, true); // mono
  dv.setUint32(24, dstRate, true);
  dv.setUint32(28, dstRate * 2, true);
  dv.setUint16(32, 2, true);
  dv.setUint16(34, 16, true);
  str(36, 'data');
  dv.setUint32(40, pcm.length * 2, true);
  new Int16Array(buf, 44).set(pcm);
  return new Uint8Array(buf);
}

export function bytesToB64(u8) {
  let s = '';
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  return btoa(s);
}

function b64ToBuffer(b64) {
  const bin = atob(b64);
  const u8 = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  return u8.buffer;
}

/** WAV parçalarını sırayla, boşluksuz çalar; düzey ölçer ve araya girildiğinde susar. */
export class Player {
  constructor() {
    this.ctx = new AudioContext();
    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 512;
    this.analyser.connect(this.ctx.destination);
    this.data = new Float32Array(this.analyser.fftSize);
    this.queue = [];
    this.playing = null;
    this.gen = 0;
    this.onIdle = null;
    this.onStart = null;
  }

  get busy() { return !!this.playing || this.queue.length > 0; }

  async enqueue(b64) {
    const gen = this.gen;
    if (this.ctx.state === 'suspended') await this.ctx.resume();
    const buf = await this.ctx.decodeAudioData(b64ToBuffer(b64));
    if (gen !== this.gen) return;
    this.queue.push(buf);
    if (!this.playing) this.next();
  }

  next() {
    const buf = this.queue.shift();
    if (!buf) { this.playing = null; this.onIdle?.(); return; }
    const s = this.ctx.createBufferSource();
    s.buffer = buf;
    s.connect(this.analyser);
    s.onended = () => { if (this.playing === s) this.next(); };
    this.playing = s;
    s.start();
    this.onStart?.();
  }

  stop() {
    this.gen++;
    this.queue = [];
    const p = this.playing;
    this.playing = null;
    try { p?.stop(); } catch { /* */ }
  }

  level() {
    if (!this.playing) return -100;
    this.analyser.getFloatTimeDomainData(this.data);
    return levelDb(this.data);
  }

  close() {
    this.stop();
    this.ctx.close().catch(() => {});
  }
}
