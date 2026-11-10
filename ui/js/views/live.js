// Canlı sesli sohbet: dinle → yazıya çevir → ajana gönder → yanıtı cümle cümle seslendir → yeniden dinle.
// Her şey yerelde çalışır: konuşma algılama tarayıcıda, Whisper ve Türkçe ses FerIDE'nin ses sunucularında.
import { S } from '../app.js';
import { h, icon, toast, confirmBox, basename, store } from '../util.js';
import { Mic, Player, encodeWav, levelDb, bytesToB64 } from '../audio.js';
import * as Chat from './chat.js';

let L = null;

const STATE_LABEL = {
  preparing: 'Hazırlanıyor…',
  listening: 'Dinliyorum',
  hearing: 'Seni duyuyorum…',
  transcribing: 'Anlamaya çalışıyorum…',
  thinking: 'Düşünüyor…',
  speaking: 'Konuşuyor',
  approval: 'Onayın gerekiyor',
  muted: 'Mikrofon kapalı',
};

// Whisper'ın sessizlikte uydurduğu bilinen Türkçe kalıplar.
const HALLUCINATIONS = [
  /^altyaz[ıi]\b/i, /izledi[ğg]iniz i[çc]in te[şs]ekk[üu]r/i, /abone ol/i, /^\[?m[üu]zik\]?$/i,
  /^te[şs]ekk[üu]rler\.?$/i, /^\.+$/, /^(hmm+|ıı+|ee+)\.?$/i, /^www\./i, /^altyaz/i,
];

export const isActive = () => !!L;

export async function open() {
  if (L) return;
  let st;
  try { st = await S.rpc.call('voice.status'); } catch (e) { toast(e.message, 'err'); return; }
  if (!st.installed) {
    const ok = await confirmBox('Canlı sohbet', 'Canlı sesli sohbet için ses paketi (Whisper konuşma tanıma + Türkçe ses) gerekir. '
      + 'Paket bilgisayarına kurulur ve tamamen yerel çalışır (yaklaşık 1,7 GB).\n\nŞimdi kurulsun mu?', 'Kur');
    if (ok) {
      S.rpc.call('setup.install', { ids: ['voice'] }).catch((e) => toast(e.message, 'err'));
      import('./setup.js').then((m) => m.open());
    }
    return;
  }
  const remote = S.settings?.provider?.kind === 'openai';
  if (!remote && !S.settings?.model?.selected && S.model?.state !== 'ready') {
    toast('Önce bir model seçin.', 'warn');
    import('./models.js').then((m) => m.open());
    return;
  }

  L = {
    state: 'preparing', muted: false, mic: new Mic(), player: new Player(), gen: 0,
    floor: -60, inSpeech: false, loudMs: 0, silenceMs: 0, uttMs: 0, utt: [], pre: [], preMs: 0,
    frameMs: 21, micDb: -100, raf: 0, text: '', inCode: false, codeSaid: false, pendingTts: 0,
    ttsChain: Promise.resolve(), agentDone: true, approval: null, bargeIn: store('live.bargein') !== false,
  };
  buildUi();
  setState('preparing');
  L.player.onIdle = () => maybeListen();
  L.player.onStart = () => { if (L && L.state !== 'approval') setState('speaking'); };
  try {
    await L.mic.start(onFrame);
    L.frameMs = (1024 / L.mic.rate) * 1000;
  } catch (e) {
    toast(`Mikrofona erişilemedi: ${e.message}`, 'err', 8000);
    close();
    return;
  }
  setSub('Ses motorları yükleniyor (ilk açılışta biraz sürebilir)…');
  try {
    await S.rpc.call('voice.warmup');
  } catch (e) {
    toast(`Ses sunucuları başlatılamadı: ${e.message}`, 'err', 10000);
    close();
    return;
  }
  if (!L) return;
  setSub('');
  if (Chat.isRunning()) { L.agentDone = false; setState('thinking'); } else setState('listening');
  tick();
}

export function close() {
  if (!L) return;
  const l = L;
  L = null;
  cancelAnimationFrame(l.raf);
  l.mic.stop();
  l.player.close();
  l.el.remove();
  document.removeEventListener('keydown', l.onKey, true);
}

// ---------------------------------------------------------------- arayüz
function buildUi() {
  const orb = h('button', { class: 'live-orb', title: 'Konuşmasını kes / dinlemeye geç', onclick: interrupt },
    h('span', { class: 'core' }), h('span', { class: 'ring r1' }), h('span', { class: 'ring r2' }));
  const label = h('div', { class: 'live-state' });
  const sub = h('div', { class: 'live-sub muted small' });
  const you = h('div', { class: 'live-you' });
  const her = h('div', { class: 'live-her' });
  const approvalBox = h('div', { class: 'live-approval hidden' });
  const muteBtn = h('button', { class: 'live-btn', title: 'Mikrofonu kapat/aç (M)', onclick: toggleMute }, icon('mic'));
  const stopBtn = h('button', { class: 'live-btn', title: 'Sözünü kes (Boşluk)', onclick: interrupt }, icon('stop'));
  const endBtn = h('button', { class: 'live-btn end', title: 'Canlı sohbeti bitir (Esc)', onclick: close }, icon('x'));
  const barge = h('input', { type: 'checkbox', checked: L.bargeIn, onchange: (e) => { L.bargeIn = e.target.checked; store('live.bargein', L.bargeIn); } });
  const modelName = S.settings?.provider?.kind === 'openai' ? S.settings.provider.model : (S.model?.model_name || basename(S.settings?.model?.selected || '').replace(/\.gguf$/i, ''));
  const el = h('div', { class: 'live' },
    h('div', { class: 'live-top' },
      h('span', { class: 'live-badge' }, h('span', { class: 'dot ok' }), 'Canlı'),
      h('span', { class: 'muted small nowrap grow' }, modelName || ''),
      h('button', { class: 'icon-btn', title: 'Kapat (Esc)', onclick: close }, icon('x'))),
    h('div', { class: 'live-stage' }, orb, label, sub),
    h('div', { class: 'live-transcript' }, you, her),
    approvalBox,
    h('div', { class: 'live-controls' }, muteBtn, stopBtn, endBtn),
    h('label', { class: 'check tiny muted live-opt', title: 'Açıkken Feride konuşurken konuşmaya başlarsan susar. Hoparlör sesi mikrofona kaçıp kendi sözünü kesiyorsa kapat ya da kulaklık kullan.' },
      barge, 'Konuşurken sözünü kesebileyim'));
  Object.assign(L, { el, orb, label, sub, you, her, approvalBox, muteBtn });
  L.onKey = (e) => {
    if (!L) return;
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
    const typing = /input|textarea|select/i.test(document.activeElement?.tagName || '');
    if (!typing && e.key === ' ') { e.preventDefault(); interrupt(); }
    if (!typing && (e.key === 'm' || e.key === 'M')) { e.preventDefault(); toggleMute(); }
  };
  document.addEventListener('keydown', L.onKey, true);
  document.getElementById('agentpanel').append(el);
}

function setState(s) {
  if (!L) return;
  L.state = s;
  L.el.dataset.state = L.muted && (s === 'listening' || s === 'hearing') ? 'muted' : s;
  L.label.textContent = L.muted && s === 'listening' ? STATE_LABEL.muted : STATE_LABEL[s] || s;
  if (s === 'listening') setSub(L.muted ? 'Konuşmak için mikrofonu aç (M).' : 'Konuşabilirsin.');
  if (s === 'hearing' || s === 'transcribing') setSub('');
  if (s === 'speaking') setSub(L.bargeIn ? 'Araya girmek için konuşmaya başla ya da küreye dokun.' : 'Susturmak için küreye dokun.');
}

function setSub(t) { if (L) L.sub.textContent = t; }

function toggleMute() {
  if (!L) return;
  L.muted = !L.muted;
  L.mic.setMuted(L.muted);
  L.muteBtn.classList.toggle('off', L.muted);
  L.muteBtn.innerHTML = '';
  L.muteBtn.append(icon(L.muted ? 'micOff' : 'mic'));
  if (L.muted && L.inSpeech) { L.inSpeech = false; L.utt = []; }
  setState(L.state === 'hearing' ? 'listening' : L.state);
}

function tick() {
  if (!L) return;
  const speaking = L.player.busy;
  const db = speaking ? L.player.level() : (L.muted ? -100 : L.micDb);
  const lvl = Math.max(0, Math.min(1, (db + 60) / 45));
  L.lvl = (L.lvl || 0) * 0.7 + lvl * 0.3;
  L.orb.style.setProperty('--lvl', L.lvl.toFixed(3));
  L.raf = requestAnimationFrame(tick);
}

// ---------------------------------------------------------------- konuşma algılama
function onFrame(f) {
  if (!L) return;
  const db = levelDb(f);
  L.micDb = db;
  const ms = L.frameMs;
  if (!L.inSpeech) {
    // Gürültü tabanı: hızlı iner, yavaş yükselir.
    L.floor = db < L.floor ? L.floor * 0.85 + db * 0.15 : L.floor * 0.997 + db * 0.003;
    L.pre.push(f);
    L.preMs += ms;
    while (L.preMs > 450 && L.pre.length > 1) { L.pre.shift(); L.preMs -= ms; }
  }
  if (L.muted || L.state === 'preparing' || L.state === 'transcribing') return;
  const playing = L.player.busy;
  // Feride konuşurken ya da çalışırken araya girmek için daha kararlı bir ses gerekir
  // (hoparlör sesi mikrofona kaçabilir, bir öksürük görevi durdurmamalı).
  const guarded = (playing || L.state === 'thinking') && L.state !== 'approval';
  if (guarded && !L.bargeIn) return;
  const thr = guarded ? Math.max(L.floor + 20, -34) : Math.max(L.floor + 11, -50);
  if (!L.inSpeech) {
    if (db > thr) {
      L.loudMs += ms;
      if (L.loudMs >= (guarded ? 300 : 130)) startUtterance();
    } else {
      L.loudMs = Math.max(0, L.loudMs - ms * 0.5);
    }
    return;
  }
  L.utt.push(f);
  L.uttMs += ms;
  if (db > L.floor + 7) L.silenceMs = 0; else L.silenceMs += ms;
  if (L.silenceMs >= 750 || L.uttMs >= 30000) endUtterance();
}

function startUtterance() {
  L.inSpeech = true;
  L.utt = L.pre.slice();
  L.uttMs = L.preMs;
  L.silenceMs = 0;
  L.loudMs = 0;
  if (L.state === 'approval') {
    if (L.player.busy) stopSpeaking(false); // yalnızca sustur; ajan onay bekliyor
    return;
  }
  if (L.player.busy || L.state === 'thinking') stopSpeaking(true);
  setState('hearing');
}

async function endUtterance() {
  const frames = L.utt;
  const speechMs = L.uttMs - L.preMs - L.silenceMs;
  L.inSpeech = false;
  L.utt = [];
  L.pre = [];
  L.preMs = 0;
  const wasApproval = L.state === 'approval';
  if (speechMs < 280) { if (!wasApproval) setState('listening'); return; }
  if (!wasApproval) setState('transcribing');
  const wav = encodeWav(frames, L.mic.rate);
  let text = '';
  try {
    text = await S.rpc.call('voice.transcribe', { audio: bytesToB64(wav), mime: 'audio/wav' });
  } catch (e) {
    toast(`Konuşma tanıma: ${e.message}`, 'err', 8000);
  }
  if (!L) return;
  text = (text || '').trim();
  if (!text || HALLUCINATIONS.some((r) => r.test(text))) {
    if (L.state === 'transcribing') setState('listening');
    return;
  }
  if (L.state === 'approval' || wasApproval) { voiceApproval(text); return; }
  L.you.textContent = text;
  L.her.textContent = '';
  sendText(text);
}

async function sendText(text) {
  L.gen++;
  L.text = '';
  L.inCode = false;
  L.codeSaid = false;
  L.agentDone = false;
  setState('thinking');
  setSub(S.settings?.agent?.thinking ? 'Düşünme modu açık; yanıt biraz gecikebilir.' : '');
  // Sözü kesilen tur kapanana kadar bekle (aynı sohbette tek görev çalışır).
  L.waitingSend = true;
  for (let i = 0; i < 50 && Chat.isRunning(); i++) await new Promise((r) => setTimeout(r, 100));
  if (!L) return;
  L.ignoreRun = false;
  L.waitingSend = false;
  const ok = await Chat.sendText(text, { voice: true });
  if (!ok && L) { L.agentDone = true; setState('listening'); }
}

// ---------------------------------------------------------------- yanıtı seslendirme
export function onAgentEvent(ev) {
  if (!L) return;
  // Sözü kesilen turun geç gelen parçaları seslendirilmez.
  if (L.ignoreRun) {
    if (ev.kind === 'done') { L.ignoreRun = false; L.agentDone = !L.waitingSend; maybeListen(); }
    return;
  }
  switch (ev.kind) {
    case 'start':
      L.agentDone = false;
      if (L.state !== 'speaking') setState('thinking');
      break;
    case 'content':
      L.her.textContent += ev.text;
      L.her.scrollTop = L.her.scrollHeight;
      L.text += ev.text;
      pumpSentences(false);
      break;
    case 'status':
      if (L.state === 'thinking') setSub(ev.text);
      break;
    case 'tool_start':
      pumpSentences(true);
      if (L.state === 'thinking') setSub(ev.summary ? `Çalışıyor: ${ev.summary}` : 'Çalışıyor…');
      break;
    case 'approval':
      pumpSentences(true);
      L.approval = ev;
      showApproval(ev);
      say('Bir işlem için onayın gerekiyor. Evet ya da hayır diyebilirsin.');
      break;
    case 'approval_resolved':
      if (L.approval?.id === ev.id) hideApproval();
      break;
    case 'done':
      pumpSentences(true);
      L.agentDone = true;
      hideApproval();
      if (ev.error) say('Bir hata oluştu, ayrıntılar sohbette.');
      maybeListen();
      break;
    default:
      break;
  }
}

function pumpSentences(final) {
  for (;;) {
    if (L.inCode) {
      const end = L.text.indexOf('```');
      if (end < 0) { L.text = L.text.slice(-2); return; }
      L.text = L.text.slice(end + 3);
      L.inCode = false;
      continue;
    }
    const fence = L.text.indexOf('```');
    if (fence >= 0) {
      const before = L.text.slice(0, fence);
      L.text = L.text.slice(fence + 3);
      L.inCode = true;
      if (before.trim()) say(before);
      if (!L.codeSaid) { L.codeSaid = true; say('Kodu ekranda gösteriyorum.'); }
      continue;
    }
    // Kısa ilk parça hızlı başlasın; sonrakiler doğal cümle grupları halinde.
    const minLen = L.pendingTts === 0 && !L.player.busy ? 12 : 60;
    const re = /[.!?…]+["'”’)\]]*\s+|\n+|[:;]\s+/g;
    let cut = -1;
    let m;
    while ((m = re.exec(L.text))) {
      const end = m.index + m[0].length;
      if (end >= minLen) { cut = end; break; }
    }
    if (cut < 0) {
      if (final) {
        // Sonda yarım kalmış ``` ihtimali yok sayılır.
        const rest = L.text.replace(/`+$/, '');
        L.text = '';
        if (rest.trim()) say(rest);
      }
      return;
    }
    const sentence = L.text.slice(0, cut);
    L.text = L.text.slice(cut);
    say(sentence);
  }
}

function speechText(t) {
  return t
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/https?:\/\/\S+/g, 'bağlantı')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/^\s*#+\s*/gm, '')
    .replace(/[*_#>|~]/g, '')
    .replace(/\p{Extended_Pictographic}|\u200d|\ufe0f/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function say(raw) {
  const text = speechText(raw);
  if (!text || !/[\p{L}\p{N}]/u.test(text)) return;
  const gen = L.gen;
  L.pendingTts++;
  // İstekler sırayla gider (TTS motoru tek iş parçacıklı); çalma sırası korunur.
  L.ttsChain = L.ttsChain.then(async () => {
    if (!L || gen !== L.gen) return;
    try {
      const b64 = await S.rpc.call('voice.speak', { text });
      if (L && gen === L.gen) await L.player.enqueue(b64);
    } catch (e) {
      if (L && gen === L.gen) setSub(`Seslendirilemedi: ${e.message}`);
    }
  }).finally(() => {
    if (!L) return;
    if (gen === L.gen) L.pendingTts = Math.max(0, L.pendingTts - 1);
    maybeListen();
  });
}

function maybeListen() {
  if (!L || L.inSpeech) return;
  if (L.state === 'approval') return;
  if (L.player.busy || L.pendingTts > 0) return;
  if (!L.agentDone) { if (L.state === 'speaking') setState('thinking'); return; }
  if (L.state !== 'listening' && L.state !== 'transcribing' && L.state !== 'hearing') setState('listening');
}

function stopSpeaking(stopAgent) {
  L.gen++;
  L.pendingTts = 0;
  L.text = '';
  L.player.stop();
  if (stopAgent && Chat.isRunning()) { L.ignoreRun = true; Chat.stopRun(); }
}

function interrupt() {
  if (!L) return;
  if (L.state === 'speaking' || L.player.busy || L.state === 'thinking') {
    stopSpeaking(true);
    L.agentDone = true;
    setState('listening');
  } else if (L.muted) {
    toggleMute();
  }
}

// ---------------------------------------------------------------- onay
function showApproval(ev) {
  setState('approval');
  setSub('"Evet" ya da "hayır" de, veya aşağıdan seç.');
  L.approvalBox.innerHTML = '';
  L.approvalBox.classList.remove('hidden');
  const answer = (a) => Chat.answerApproval(ev.id, a);
  L.approvalBox.append(
    h('div', { class: 'q' }, icon('shield'), ev.reason),
    h('div', { class: 'mono small nowrap', title: ev.summary }, ev.summary),
    h('div', { class: 'acts' },
      h('button', { class: 'btn primary sm', onclick: () => answer('allow') }, icon('check'), 'İzin ver'),
      h('button', { class: 'btn danger sm', onclick: () => answer('deny') }, 'Reddet')));
}

function hideApproval() {
  if (!L || !L.approval) return;
  L.approval = null;
  L.approvalBox.classList.add('hidden');
  L.approvalBox.innerHTML = '';
  setState(L.player.busy ? 'speaking' : L.agentDone ? 'listening' : 'thinking');
}

function voiceApproval(text) {
  const t = text.toLocaleLowerCase('tr-TR');
  if (!L.approval) { L.you.textContent = text; sendText(text); return; }
  if (/\b(hay[ıi]r|reddet|iptal|yapma|istemiyorum|dur)\b/.test(t)) Chat.answerApproval(L.approval.id, 'deny');
  else if (/\b(evet|onayl[ıi]yorum|onay|izin ver|tamam|olur|yap|devam)\b/.test(t)) Chat.answerApproval(L.approval.id, 'allow');
  else say('Anlayamadım. Evet ya da hayır der misin?');
}
