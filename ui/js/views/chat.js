// Ajan paneli: sohbet, araç kartları, onaylar, yapılacaklar, ses.
import { S, placementLabel, saveSettings } from '../app.js';
import { h, icon, toast, renderMarkdown, basename, store, confirmBox, copyText, fmtBytes } from '../util.js';
import { Mic, encodeWav, bytesToB64 } from '../audio.js';
import * as Editor from './editor.js';
import * as Sessions from './sessions.js';
import * as Live from './live.js';

let root;
let msgsEl;
let todosEl;
let titleEl;
let input;
let sendBtn;
let attachRow;
let session = store('session') || null;
let meta = null;
let running = false;
let attachments = []; // dataURL
let live = null; // canlı tur durumu
let checkpoints = [];
let dictation = null; // { mic, frames }
let footEl = null;
let lastUsage = null; // son turun toplam kullanımı
let modelCache = null;

export const currentId = () => session;

export function init(el) {
  root = el;
  root.innerHTML = '';
  titleEl = h('div', { class: 'title grow' }, 'Yeni sohbet');
  const head = h('div', { class: 'chat-head' },
    icon('sparkles'), titleEl,
    h('button', { class: 'icon-btn', title: 'Sohbet geçmişi', onclick: () => import('../app.js').then((a) => a.showSide('sessions')) }, icon('chat')),
    h('button', { class: 'icon-btn', title: 'Yeni sohbet (Ctrl+Shift+N)', onclick: newChat }, icon('plus')));
  msgsEl = h('div', { id: 'messages' });
  todosEl = h('div', { class: 'todos hidden' });
  input = h('textarea', { rows: 2, placeholder: 'Feride\'ye yaz… (Enter gönderir, Shift+Enter yeni satır, görsel yapıştırabilirsin)' });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
  });
  input.addEventListener('input', autosize);
  input.addEventListener('paste', (e) => {
    for (const item of e.clipboardData?.items || []) {
      if (item.type.startsWith('image/')) { e.preventDefault(); addImage(item.getAsFile()); }
    }
  });
  const fileIn = h('input', { type: 'file', accept: 'image/*', multiple: true, class: 'hidden' });
  fileIn.addEventListener('change', () => { for (const f of fileIn.files) addImage(f); fileIn.value = ''; });
  attachRow = h('div', { class: 'attach-row hidden' });
  sendBtn = h('button', { class: 'send-btn', title: 'Gönder', onclick: () => (running ? stop() : send()) }, icon('send'));
  const micBtn = h('button', { class: 'icon-btn mic', title: 'Sesle yaz: konuş, bitince tekrar bas (ses paketi gerekir)', onclick: () => toggleMic(micBtn) }, icon('mic'));
  const liveBtn = h('button', { class: 'live-start', title: 'Canlı sesli sohbet (Ctrl+Shift+V)', onclick: () => Live.open() }, icon('waves'), h('span', {}, 'Canlı'));
  footEl = h('div', { class: 'composer-foot' });
  const composer = h('div', { id: 'composer' },
    h('div', { class: 'chat-inner' },
      h('div', { class: 'composer-box', ondragover: (e) => e.preventDefault(), ondrop: onDrop },
        attachRow, input,
        h('div', { class: 'composer-tools' },
          h('button', { class: 'icon-btn', title: 'Görsel ekle', onclick: () => fileIn.click() }, icon('image')),
          micBtn, fileIn,
          h('span', { class: 'spacer' }),
          h('span', { class: 'muted tiny', id: 'composer-hint' }),
          liveBtn,
          sendBtn)),
      footEl));
  root.append(head, msgsEl, todosEl, composer);
  if (session) load(session); else renderEmpty();
  updateHint();
}

export function updateHint() {
  const el = document.getElementById('composer-hint');
  if (!el) return;
  const m = S.model;
  el.textContent = S.settings?.provider?.kind === 'openai' ? 'uzak model' : m?.state === 'ready' ? `${placementLabel(m.placement)} • ${Math.round((m.ctx || 0) / 1024)}K` : '';
  renderFoot();
}

// ---------------------------------------------------------------- alt çubuk: düşünme, model, kullanım
export function fmtTok(n) {
  if (n == null) return '–';
  if (n < 1000) return String(n);
  if (n < 10000) return `${(n / 1000).toFixed(1).replace('.', ',')}K`;
  return `${Math.round(n / 1000)}K`;
}

const fmtNum = (v, d = 1) => (v == null ? '–' : v.toFixed(d).replace('.', ','));

function usageTitle(u) {
  return [
    `Girdi (bağlam): ${u.input?.toLocaleString('tr-TR') ?? '–'} token${u.ctx ? ` / ${u.ctx.toLocaleString('tr-TR')}` : ''}`,
    u.steps > 1 ? `Bu turda işlenen toplam girdi: ${u.input_total?.toLocaleString('tr-TR')} token (${u.steps} model adımı)` : null,
    u.cached ? `Önbellekten gelen: ${u.cached.toLocaleString('tr-TR')} token` : null,
    `Çıktı: ${u.output?.toLocaleString('tr-TR') ?? '–'} token`,
    `Ortalama üretim hızı: ${fmtNum(u.tps)} token/sn`,
    u.prompt_tps ? `İstem işleme hızı: ${fmtNum(u.prompt_tps, 0)} token/sn` : null,
    u.gen_seconds ? `Üretim süresi: ${fmtNum(u.gen_seconds)} sn` : null,
  ].filter(Boolean).join('\n');
}

function statsEl(u, seconds) {
  if (!u) return null;
  return h('div', { class: 'turn-stats', title: usageTitle(u) },
    h('span', {}, '↑ ', h('b', {}, fmtTok(u.input)), ' girdi'),
    h('span', {}, '↓ ', h('b', {}, fmtTok(u.output)), ' çıktı'),
    h('span', {}, icon('zap'), h('b', {}, fmtNum(u.tps)), ' token/sn'),
    seconds ? h('span', {}, `${fmtNum(seconds, seconds < 10 ? 1 : 0)} sn`) : null);
}

function renderFoot() {
  if (!footEl) return;
  footEl.innerHTML = '';
  const thinking = !!S.settings?.agent?.thinking;
  const think = h('button', {
    class: `pill ${thinking ? 'on' : ''}`,
    title: thinking
      ? 'Düşünme açık: model yanıt vermeden önce akıl yürütür (daha isabetli, daha yavaş). Kapatmak için tıkla.'
      : 'Düşünme kapalı: model doğrudan yanıt verir (daha hızlı). Açmak için tıkla. Qwen3 gibi düşünebilen modellerde etkilidir.',
    onclick: async () => {
      await saveSettings({ agent: { thinking: !thinking } }).catch(() => {});
      renderFoot();
    },
  }, icon('brain'), h('span', {}, 'Düşünme'), h('span', { class: 'sw' }));

  const remote = S.settings?.provider?.kind === 'openai';
  const st = S.model?.state || 'idle';
  const dot = remote ? 'ok' : { ready: 'ok', starting: 'warn', stopping: 'warn', failed: 'err' }[st] || '';
  let name;
  if (remote) name = S.settings.provider.model || 'Uzak model';
  else if (S.model?.model_name && st !== 'idle') name = S.model.model_name;
  else name = S.settings?.model?.selected ? basename(S.settings.model.selected).replace(/\.gguf$/i, '') : 'Model seç';
  const picker = h('button', { class: 'pill model-pick', title: 'Model seç', onclick: (e) => modelMenu(e.currentTarget) },
    h('span', { class: `dot ${dot}` }), h('span', { class: 'nowrap name' }, name),
    st === 'starting' && !remote ? h('span', { class: 'muted' }, 'yükleniyor…') : null, icon('chevD'));

  footEl.append(think, picker, h('span', { class: 'spacer' }));
  const u = lastUsage;
  if (u) {
    const pct = u.ctx && u.input ? Math.min(100, Math.round((u.input / u.ctx) * 100)) : null;
    footEl.append(h('span', { class: 'foot-stats', title: usageTitle(u) },
      h('span', {}, '↑', fmtTok(u.input)), h('span', {}, '↓', fmtTok(u.output)),
      u.tps ? h('span', {}, `${fmtNum(u.tps)} t/s`) : null,
      pct != null ? h('span', { class: 'ctxbar', title: `Bağlam doluluğu %${pct}` }, h('i', { style: { width: `${pct}%` } })) : null));
  }
}

async function modelMenu(anchor) {
  document.querySelectorAll('.menu').forEach((m) => m.remove());
  const menu = h('div', { class: 'menu model-menu' }, h('div', { class: 'status-line' }, icon('loader', 'spin'), 'Modeller yükleniyor…'));
  document.body.append(menu);
  const place = () => {
    const r = anchor.getBoundingClientRect();
    menu.style.left = `${Math.max(8, Math.min(r.left, innerWidth - menu.offsetWidth - 8))}px`;
    menu.style.bottom = `${innerHeight - r.top + 6}px`;
  };
  place();
  const off = (e) => {
    if (e.type === 'keydown' ? e.key === 'Escape' : !menu.contains(e.target) && !anchor.contains(e.target)) {
      menu.remove();
      document.removeEventListener('mousedown', off);
      document.removeEventListener('keydown', off);
    }
  };
  setTimeout(() => { document.addEventListener('mousedown', off); document.addEventListener('keydown', off); }, 0);
  try {
    modelCache = (await S.rpc.call('models.list')).models;
  } catch (e) { modelCache = modelCache || []; toast(e.message, 'err'); }
  if (!menu.isConnected) return;
  menu.innerHTML = '';
  const remote = S.settings?.provider?.kind === 'openai';
  const runningPath = S.model?.state !== 'idle' ? S.model?.model_path : null;
  const pick = async (m) => {
    menu.remove();
    if (running) { toast('Ajan çalışırken model değiştirilemez; önce durdurun.', 'warn'); return; }
    if (remote) await saveSettings({ provider: { kind: 'local' } }).catch(() => {});
    if (runningPath === m.path && S.model?.state === 'ready') return;
    try {
      await S.rpc.call('models.start', { model: m.path });
      toast(`${m.name} yükleniyor…`);
    } catch (e) { toast(e.message, 'err'); }
  };
  if (remote) {
    menu.append(h('div', { class: 'mi sel' }, h('span', { class: 'dot ok' }), h('div', { class: 'grow' }, h('div', {}, S.settings.provider.model || 'Uzak model'), h('div', { class: 'tiny muted' }, 'OpenAI uyumlu uç nokta'))));
    menu.append(h('div', { class: 'sep' }));
  }
  menu.append(h('div', { class: 'mh' }, 'Yerel modeller'));
  if (!modelCache.length) menu.append(h('div', { class: 'tiny muted', style: { padding: '6px 10px' } }, 'Henüz model yok.'));
  for (const m of modelCache) {
    const isRun = !remote && runningPath === m.path;
    const isSel = !remote && S.settings?.model?.selected === m.path;
    menu.append(h('div', { class: `mi ${isSel ? 'sel' : ''}`, title: m.path, onclick: () => pick(m) },
      h('span', { class: `dot ${isRun ? (S.model.state === 'ready' ? 'ok' : 'warn') : ''}` }),
      h('div', { class: 'grow', style: { minWidth: 0 } },
        h('div', { class: 'nowrap' }, m.name),
        h('div', { class: 'tiny muted' }, [fmtBytes(m.size_bytes), m.quant, m.mmproj ? 'görsel ✓' : null].filter(Boolean).join(' · '))),
      isSel ? icon('check') : null));
  }
  menu.append(h('div', { class: 'sep' }));
  if (!remote && (S.model?.state === 'ready' || S.model?.state === 'starting')) {
    menu.append(h('div', { class: 'mi', onclick: () => { menu.remove(); S.rpc.call('models.stop'); } }, icon('stop'), 'Modeli durdur (belleği boşalt)'));
  }
  menu.append(h('div', { class: 'mi', onclick: () => { menu.remove(); import('./models.js').then((x) => x.open()); } }, icon('cpu'), 'Model Merkezi…'));
  place();
}

function autosize() {
  input.style.height = 'auto';
  input.style.height = `${Math.min(260, input.scrollHeight)}px`;
}

function addImage(file) {
  if (!file || file.size > 15 * 1024 * 1024) { toast('Görsel çok büyük (en fazla 15 MB).', 'warn'); return; }
  const r = new FileReader();
  r.onload = () => { attachments.push(r.result); renderAttachments(); };
  r.readAsDataURL(file);
}

function onDrop(e) {
  e.preventDefault();
  for (const f of e.dataTransfer?.files || []) {
    if (f.type.startsWith('image/')) addImage(f);
  }
}

function renderAttachments() {
  attachRow.innerHTML = '';
  attachRow.classList.toggle('hidden', !attachments.length);
  attachments.forEach((src, i) => attachRow.append(h('div', { class: 'att' }, h('img', { src }), h('span', { class: 'x', onclick: () => { attachments.splice(i, 1); renderAttachments(); } }, '×'))));
}

export function focusComposer() { input?.focus(); }

export function mention(path) {
  const rel = S.info?.workspace && path.startsWith(S.info.workspace) ? path.slice(S.info.workspace.length + 1) : path;
  input.value += `${input.value && !input.value.endsWith(' ') ? ' ' : ''}\`${rel.replace(/\\/g, '/')}\` `;
  autosize();
  input.focus();
}

export const isRunning = () => running;
export function stopRun() { return stop(); }
export function answerApproval(id, answer) {
  return S.rpc.call('chat.approve', { session, id, answer }).catch((e) => toast(e.message, 'err'));
}

function setRunning(r) {
  running = r;
  sendBtn.classList.toggle('stop', r);
  sendBtn.title = r ? 'Durdur' : 'Gönder';
  sendBtn.innerHTML = '';
  sendBtn.append(icon(r ? 'stop' : 'send'));
}

function renderEmpty() {
  msgsEl.innerHTML = '';
  const ex = (t) => h('div', { class: 'card', style: { padding: '9px 12px' }, onclick: () => { input.value = t; autosize(); input.focus(); } }, h('p', { style: { color: 'var(--fg-2)' } }, t));
  msgsEl.append(h('div', { class: 'chat-inner' }, h('div', { style: { padding: '30px 6px 10px', textAlign: 'center' } },
    h('div', { class: 'hero-setup', style: { padding: '10px 0' } }, h('div', { class: 'logo', style: { width: '48px', height: '48px', fontSize: '22px', borderRadius: '14px' } }, 'F')),
    h('h3', { style: { margin: '4px 0' } }, 'Merhaba, ben Feride.'),
    h('div', { class: 'muted small' }, 'Bu bilgisayarda, verilerin dışarı çıkmadan çalışırım. Ne yapalım?')),
    h('div', { class: 'col', style: { gap: '6px', marginTop: '12px' } },
      ex('Bu projenin yapısını incele ve kısa bir özet çıkar.'),
      ex('Çalışma alanındaki hataları bul ve düzelt; sonunda testleri çalıştır.'),
      ex('Masaüstündeki rapor.pdf dosyasını oku ve 5 maddede özetle.'),
      ex('Bugünün yapay zeka haberlerini araştır ve kaynaklarıyla özetle.'))));
  titleEl.textContent = 'Yeni sohbet';
  todosEl.classList.add('hidden');
}

export function newChat() {
  if (running) { toast('Önce çalışan görevi durdurun ya da bitmesini bekleyin.', 'warn'); }
  session = null;
  meta = null;
  checkpoints = [];
  store('session', null);
  renderEmpty();
  setRunning(false);
  input?.focus();
  Sessions.refresh();
}

export async function reloadCurrent() { if (session) load(session); }

export async function load(id) {
  let data;
  try { data = await S.rpc.call('chat.load', { id }); } catch (e) { toast(e.message, 'err'); newChat(); return; }
  session = id;
  store('session', id);
  meta = data.meta;
  checkpoints = data.checkpoints || [];
  titleEl.textContent = meta.title;
  renderMessages(data.messages);
  renderTodos(data.todos);
  setRunning(data.running);
  if (data.running) {
    live = newLiveBlock();
    live.status.append(icon('loader', 'spin'), 'Çalışıyor…');
  }
  Sessions.refresh();
  scrollBottom(true);
}

// ---------------------------------------------------------------- geçmişi çiz
function renderMessages(messages) {
  msgsEl.innerHTML = '';
  live = null;
  lastUsage = null;
  const userTurns = messages.filter((m) => m.role === 'user').length;
  let turnNo = (meta?.turns || userTurns) - userTurns;
  let block = null;
  const cards = new Map();
  for (const m of messages) {
    if (m.role === 'user') {
      turnNo += 1;
      block = null;
      msgsEl.append(userBubble(m, turnNo));
    } else if (m.role === 'assistant') {
      if (!block) { block = assistantBlock(); msgsEl.append(block.el); }
      if (m.reasoning) block.body.append(reasoningEl(m.reasoning));
      if (m.content) block.body.append(renderMarkdown(typeof m.content === 'string' ? m.content : ''));
      if (m.usage) { block.body.append(statsEl(m.usage, m.usage.seconds)); lastUsage = m.usage; }
      for (const tc of m.tool_calls || []) {
        let args = {};
        try { args = JSON.parse(tc.function.arguments || '{}'); } catch { /* */ }
        const c = toolCard(tc.id, tc.function.name, summarize(tc.function.name, args), false);
        cards.set(tc.id, c);
        block.body.append(c.el);
      }
    } else if (m.role === 'tool') {
      const c = cards.get(m.tool_call_id);
      if (c) finishCard(c, isOkOutput(m.content), m.content, null);
    }
  }
  if (!messages.length) renderEmpty();
  renderFoot();
}

function isOkOutput(content) {
  const t = String(content || '');
  return !(t.startsWith('HATA') || t.startsWith('ENGELLENDİ') || t.startsWith('Kullanıcı bu işlemi reddetti') || /^çıkış kodu: (?!0\n)/.test(t));
}

function userBubble(m, turnNo) {
  let text = m.content;
  const imgs = [];
  if (Array.isArray(m.content)) {
    text = m.content.filter((p) => p.type === 'text').map((p) => p.text).join('\n');
    for (const p of m.content) if (p.type === 'image_url') imgs.push(p.image_url.url);
  }
  const cp = checkpoints.find((c) => c.turn === turnNo);
  const foot = h('div', { class: 'turn-foot', style: { justifyContent: 'flex-end' } },
    h('button', { class: 'btn sm ghost', title: 'Kopyala', onclick: () => copyText(text) }, icon('copy')),
    cp ? h('button', { class: 'btn sm ghost', title: `Bu mesajdan sonra ajanın değiştirdiği ${cp.files.length}+ dosyayı geri al`, onclick: () => revert(turnNo) }, icon('undo'), 'Değişiklikleri geri al') : null);
  return h('div', { class: 'msg user' }, h('div', { class: 'bubble' }, m.voice ? icon('mic', 'voice-mark') : null, text), imgs.length ? h('div', { class: 'imgs' }, imgs.map((src) => h('img', { src }))) : null, foot);
}

async function revert(turn) {
  const files = checkpoints.filter((c) => c.turn >= turn).flatMap((c) => c.files);
  const list = [...new Set(files)].slice(0, 20).map((f) => `• ${f}`).join('\n');
  if (!(await confirmBox('Değişiklikleri geri al', `Ajanın bu mesajdan sonra yaptığı dosya değişiklikleri geri alınacak:\n\n${list}`, 'Geri al', true))) return;
  try {
    const restored = await S.rpc.call('chat.revert', { id: session, turn });
    toast(`${restored.length} dosya geri alındı.`, 'ok');
    for (const p of restored) Editor.reloadIfOpen(p);
    load(session);
  } catch (e) { toast(e.message, 'err'); }
}

function assistantBlock() {
  const body = h('div');
  const el = h('div', { class: 'msg assistant' }, h('div', { class: 'who' }, h('div', { class: 'logo' }, 'F'), 'Feride'), body);
  return { el, body };
}

function reasoningEl(text) {
  const body = h('div', { class: 'body' }, text);
  const d = h('details', { class: 'reasoning' }, h('summary', {}, icon('brain'), 'Düşünce'), body);
  return Object.assign(d, { bodyEl: body });
}

const TOOL_LABEL = {
  read_file: 'Dosya okundu', write_file: 'Dosya yazıldı', edit_file: 'Dosya düzenlendi', list_directory: 'Klasör listelendi', glob: 'Dosya arandı',
  grep: 'İçerik arandı', run_command: 'Komut', web_search: 'Web araması', fetch_url: 'Sayfa okundu', todo_write: 'Yapılacaklar', use_skill: 'Skill',
  remember: 'Hafızaya kaydedildi', recall: 'Hafıza', spawn_agent: 'Alt ajan', read_document: 'Belge okundu', edit_document: 'Belge', open_in_system: 'Açıldı',
  save_skill: 'Skill kaydedildi', process: 'Arka plan işlemi',
};

function summarize(name, a) {
  switch (name) {
    case 'run_command': return `$ ${a.command || ''}`;
    case 'read_file': case 'write_file': case 'edit_file': case 'read_document': case 'list_directory': return a.path || '.';
    case 'glob': return a.pattern;
    case 'grep': return `/${a.pattern}/ ${a.include || ''}`;
    case 'web_search': return a.query;
    case 'fetch_url': return a.url;
    case 'use_skill': return a.name;
    case 'spawn_agent': return a.task;
    case 'edit_document': return a.output_path;
    default: return name.startsWith('mcp__') ? JSON.stringify(a).slice(0, 160) : '';
  }
}

function toolCard(id, name, summary, isRunning, sub = false) {
  const st = h('span', { class: 'st' }, isRunning ? icon('loader', 'spin') : '');
  const pre = h('pre');
  const label = name.startsWith('mcp__') ? `MCP ${name.slice(5).replace('__', ' → ')}` : (TOOL_LABEL[name] || name);
  const el = h('div', { class: `tool ${sub ? 'sub' : ''}` },
    h('div', { class: 'th', onclick: () => el.classList.toggle('open') }, icon(iconFor(name)), h('b', {}, label), h('span', { class: 'sum', title: summary }, summary || ''), st),
    h('div', { class: 'tb' }, pre));
  return { id, el, st, pre, name };
}

function iconFor(n) {
  if (n === 'run_command' || n === 'process') return 'terminal';
  if (n.includes('search') || n === 'grep' || n === 'glob') return 'search';
  if (n.includes('write') || n.includes('edit')) return 'edit';
  if (n === 'spawn_agent') return 'layers';
  if (n === 'remember' || n === 'recall') return 'brain';
  if (n.startsWith('mcp__')) return 'plug';
  if (n === 'use_skill' || n === 'save_skill') return 'sparkles';
  return 'file';
}

function finishCard(c, ok, output, ui) {
  c.st.innerHTML = '';
  c.st.append(ok ? h('span', { class: 'badge ok' }, icon('check')) : h('span', { class: 'badge err' }, 'hata'));
  c.pre.innerHTML = '';
  if (ui?.diff) {
    c.pre.classList.add('diff');
    for (const line of ui.diff.split('\n')) {
      const cls = line.startsWith('+') && !line.startsWith('+++') ? 'add' : line.startsWith('-') && !line.startsWith('---') ? 'del' : line.startsWith('@@') ? 'hunk' : '';
      c.pre.append(cls ? h('span', { class: cls }, line) : `${line}\n`);
    }
    if (ui.path) c.pre.prepend(h('div', { style: { marginBottom: '6px' } }, h('a', { href: '#', onclick: (e) => { e.preventDefault(); Editor.openFile(ui.path); } }, `Aç: ${basename(ui.path)}`)));
  } else {
    c.pre.textContent = output || '';
  }
  if (!ok) c.el.classList.add('open');
}

// ---------------------------------------------------------------- canlı akış
function newLiveBlock() {
  const b = assistantBlock();
  const status = h('div', { class: 'status-line' });
  b.body.append(status);
  msgsEl.append(b.el);
  const stats = h('div', { class: 'turn-stats-slot' });
  b.el.append(stats);
  return { block: b, status, stats, textEl: null, text: '', reasoningEl: null, cards: new Map(), approvals: new Map(), renderTimer: null };
}

function liveText() {
  if (!live.textEl) {
    live.text = '';
    live.textEl = h('div');
    live.block.body.insertBefore(live.textEl, live.status);
  }
  return live.textEl;
}

function flushText() {
  if (!live?.textEl) return;
  live.textEl.innerHTML = '';
  live.textEl.append(renderMarkdown(live.text));
}

function scrollBottom(force) {
  const near = msgsEl.scrollHeight - msgsEl.scrollTop - msgsEl.clientHeight < 160;
  if (force || near) msgsEl.scrollTop = msgsEl.scrollHeight;
}

export function onAgentEvent(ev) {
  if (ev.kind === 'todos' && ev.session === session) renderTodos(ev.todos);
  if (ev.session !== session) return;
  if (!live && ev.kind !== 'done') live = newLiveBlock();
  handleEvent(ev);
  Live.onAgentEvent(ev);
}

function handleEvent(ev) {
  switch (ev.kind) {
    case 'start':
      if (ev.title_needed) setTimeout(() => S.rpc.call('chat.load', { id: session }).then((d) => { meta = d.meta; titleEl.textContent = d.meta.title; }), 300);
      live.status.innerHTML = '';
      live.status.append(icon('loader', 'spin'), 'Düşünüyor…');
      break;
    case 'status':
      live.status.innerHTML = '';
      live.status.append(icon('loader', 'spin'), ev.text);
      break;
    case 'reasoning':
      if (!live.reasoningEl) { live.reasoningEl = reasoningEl(''); live.block.body.insertBefore(live.reasoningEl, live.status); }
      live.reasoningEl.bodyEl.textContent += ev.text;
      live.status.innerHTML = '';
      live.status.append(icon('brain'), 'Düşünüyor…');
      break;
    case 'content':
      liveText();
      live.text += ev.text;
      if (!live.renderTimer) live.renderTimer = setTimeout(() => { live && (live.renderTimer = null, flushText(), scrollBottom()); }, 70);
      live.status.innerHTML = '';
      break;
    case 'tool_start': {
      flushText();
      live.textEl = null;
      live.reasoningEl = null;
      const c = toolCard(ev.id, ev.name, ev.summary, true, ev.sub);
      live.cards.set(ev.id, c);
      live.block.body.insertBefore(c.el, live.status);
      live.status.innerHTML = '';
      live.status.append(icon('loader', 'spin'), `${TOOL_LABEL[ev.name] || ev.name}…`);
      break;
    }
    case 'tool_end': {
      const c = live.cards.get(ev.id);
      if (c) finishCard(c, ev.ok, ev.output, ev.ui);
      if (ev.ui?.path) Editor.reloadIfOpen(ev.ui.path);
      live.status.innerHTML = '';
      live.status.append(icon('loader', 'spin'), 'Devam ediyor…');
      break;
    }
    case 'approval':
      showApproval(ev);
      break;
    case 'usage':
      if (ev.turn) {
        lastUsage = ev.turn;
        live.stats.innerHTML = '';
        live.stats.append(statsEl(ev.turn));
        renderFoot();
      }
      break;
    case 'approval_resolved': {
      const a = live.approvals.get(ev.id);
      if (a) a.remove();
      break;
    }
    case 'done':
      finishLive(ev);
      break;
    default:
      break;
  }
  scrollBottom();
}

function showApproval(ev) {
  const msgInput = h('input', { type: 'text', placeholder: 'Reddederken not (isteğe bağlı): ör. "önce testleri çalıştır"', style: { width: '100%' } });
  const answer = (a) => S.rpc.call('chat.approve', { session, id: ev.id, answer: a, message: msgInput.value }).catch((e) => toast(e.message, 'err'));
  const el = h('div', { class: 'approval' },
    h('div', { class: 'q' }, icon('shield'), `Onay gerekiyor: ${ev.reason}`),
    h('div', { class: 'mono small' }, ev.summary),
    ev.preview ? diffPre(ev.preview) : null,
    h('div', { class: 'acts' },
      h('button', { class: 'btn primary sm', onclick: () => answer('allow') }, icon('check'), 'İzin ver'),
      h('button', { class: 'btn sm', onclick: () => answer('session') }, 'Bu sohbette hep izin ver'),
      h('button', { class: 'btn danger sm', onclick: () => answer('deny') }, 'Reddet')),
    h('div', { style: { marginTop: '6px' } }, msgInput));
  live.approvals.set(ev.id, el);
  live.block.body.insertBefore(el, live.status);
  live.status.innerHTML = '';
  live.status.append(icon('shield'), 'Onayınız bekleniyor');
  if (document.hidden && 'Notification' in window && Notification.permission === 'granted') new Notification('FerIDE: onay gerekiyor', { body: ev.summary });
}

function diffPre(text) {
  const pre = h('pre', { class: 'diff' });
  for (const line of text.split('\n')) {
    const cls = line.startsWith('+') && !line.startsWith('+++') ? 'add' : line.startsWith('-') && !line.startsWith('---') ? 'del' : line.startsWith('@@') ? 'hunk' : '';
    pre.append(cls ? h('span', { class: cls }, line) : `${line}\n`);
  }
  return pre;
}

async function finishLive(ev) {
  setRunning(false);
  const reasons = { cancelled: 'Durduruldu.', max_steps: 'En fazla adım sayısına ulaşıldı. "Devam et" yazarak sürdürebilirsiniz.', loop: 'Aynı işlem art arda tekrarlandığı için durduruldu.', length: 'Yanıt uzunluk sınırına ulaştı; "devam et" yazın.' };
  if (live) {
    clearTimeout(live.renderTimer);
    flushText();
    live.status.remove();
    for (const a of live.approvals.values()) a.remove();
    if (ev.usage) { lastUsage = ev.usage; live.stats.innerHTML = ''; live.stats.append(statsEl(ev.usage, ev.seconds)); renderFoot(); }
    if (ev.error) live.block.body.append(h('div', { class: 'error-box' }, ev.error));
    else if (reasons[ev.reason]) live.block.body.append(h('div', { class: 'status-line' }, icon('info'), reasons[ev.reason]));
    const finalText = live.text;
    live = null;
    if (S.settings?.voice?.auto_speak && finalText && !ev.error && !Live.isActive()) speak(finalText);
  }
  // Kalıcı geçmişle eşitle (geri alma düğmeleri, kimlikler). Hata ve durdurma notları geçmişe
  // yazılmadığı için yeniden çizimden sonra tekrar eklenir.
  const note = () => {
    const parts = [];
    if (ev.error) parts.push(h('div', { class: 'error-box' }, ev.error));
    else if (reasons[ev.reason]) parts.push(h('div', { class: 'status-line' }, icon('info'), reasons[ev.reason]));
    if (ev.usage && ev.reason !== 'completed' && ev.reason !== 'length') parts.push(statsEl(ev.usage, ev.seconds));
    if (!parts.length) return;
    let body = msgsEl.lastElementChild?.classList.contains('assistant') ? msgsEl.lastElementChild.lastElementChild : null;
    if (!body) { const b = assistantBlock(); msgsEl.append(b.el); body = b.body; }
    body.append(...parts);
  };
  setTimeout(() => session && S.rpc.call('chat.load', { id: session }).then((d) => {
    meta = d.meta;
    checkpoints = d.checkpoints || [];
    titleEl.textContent = d.meta.title;
    renderMessages(d.messages);
    note();
    scrollBottom(true);
  }).catch(() => {}), 150);
  if (document.hidden && 'Notification' in window && Notification.permission === 'granted') new Notification('FerIDE', { body: ev.error ? 'Görev hatayla bitti.' : 'Görev tamamlandı.' });
}

async function send() {
  const text = input.value.trim();
  if (!text || running) return;
  const images = attachments.slice();
  input.value = '';
  attachments = [];
  renderAttachments();
  autosize();
  if (!(await submit(text, images, false)) && !input.value) {
    // Gönderilemediyse yazılanı geri koy.
    input.value = text;
    attachments = images;
    renderAttachments();
    autosize();
  }
}

/** Canlı sesli sohbetten gelen metni gönderir. */
export async function sendText(text, { voice = false } = {}) {
  if (running) return false;
  return submit(text, [], voice);
}

async function submit(text, images, voice) {
  if (S.settings?.provider?.kind !== 'openai' && S.model?.state !== 'ready' && S.model?.state !== 'starting' && !S.settings?.model?.selected) {
    toast('Önce Model Merkezi\'nden bir model seçin.', 'warn');
    import('./models.js').then((m) => m.open());
    return false;
  }
  if ('Notification' in window && Notification.permission === 'default') Notification.requestPermission().catch(() => {});
  if (!session) msgsEl.innerHTML = '';
  const content = images.length ? [{ type: 'text', text }, ...images.map((u) => ({ type: 'image_url', image_url: { url: u } }))] : text;
  msgsEl.append(userBubble({ content, voice }, 0));
  setRunning(true);
  live = newLiveBlock();
  live.status.append(icon('loader', 'spin'), 'Gönderiliyor…');
  scrollBottom(true);
  try {
    const r = await S.rpc.call('chat.send', { session, text, images, voice });
    if (!session) { session = r.session; store('session', session); Sessions.refresh(); }
    return true;
  } catch (e) {
    setRunning(false);
    if (live) { live.status.remove(); live.block.body.append(h('div', { class: 'error-box' }, e.message)); live = null; }
    return false;
  }
}

async function stop() {
  if (session) await S.rpc.call('chat.stop', { session }).catch(() => {});
}

function renderTodos(todos) {
  todosEl.innerHTML = '';
  if (!todos?.length) { todosEl.classList.add('hidden'); return; }
  todosEl.classList.remove('hidden');
  const done = todos.filter((t) => t.status === 'completed').length;
  const list = h('ul', {}, todos.map((t) => h('li', { class: t.status }, t.status === 'completed' ? icon('check') : t.status === 'in_progress' ? icon('loader', 'spin') : h('span', { style: { width: '16px', display: 'inline-block' } }, '○'), t.content)));
  const collapsed = store('todos.collapsed');
  if (collapsed) list.classList.add('hidden');
  todosEl.append(h('div', { class: 'th', onclick: () => { list.classList.toggle('hidden'); store('todos.collapsed', list.classList.contains('hidden')); } }, icon('check'), `Yapılacaklar ${done}/${todos.length}`), list);
}

// ---------------------------------------------------------------- ses
async function toggleMic(btn) {
  if (dictation) {
    const { mic, frames } = dictation;
    dictation = null;
    btn.classList.remove('rec');
    const rate = mic.rate;
    mic.stop();
    if (frames.length * 1024 < rate * 0.3) return; // çok kısa
    toast('Konuşma yazıya çevriliyor…', '', 2000);
    try {
      // 16 kHz mono WAV: STT sunucusu ffmpeg olmadan da çözer.
      // Sesle yazmada beklemek sorun değil: en doğru model.
      const text = await S.rpc.call('voice.transcribe', { audio: bytesToB64(encodeWav(frames, rate)), mime: 'audio/wav', quality: 'accurate' });
      if (text) input.value += (input.value && !input.value.endsWith(' ') ? ' ' : '') + text;
      autosize();
      input.focus();
    } catch (e) { toast(e.message, 'err', 8000); }
    return;
  }
  const mic = new Mic();
  const frames = [];
  try {
    await mic.start((f) => { if (frames.length < 60 * 50) frames.push(f); });
  } catch (e) { toast(`Mikrofona erişilemedi: ${e.message}`, 'err'); return; }
  dictation = { mic, frames };
  btn.classList.add('rec');
  S.rpc.call('voice.warmup').catch(() => {}); // kayıt sürerken STT'yi ısıt
}

let audioEl = null;
export async function speak(text) {
  try {
    const clean = text.replace(/```[\s\S]*?```/g, ' kod bloğu ').replace(/[#*_`>|]/g, '').slice(0, 3000);
    const b64 = await S.rpc.call('voice.speak', { text: clean });
    audioEl?.pause();
    audioEl = new Audio(`data:audio/wav;base64,${b64}`);
    audioEl.play();
  } catch (e) { toast(`Sesli yanıt: ${e.message}`, 'warn'); }
}

