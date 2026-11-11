// FerIDE arayüz giriş noktası.
import { Rpc } from './rpc.js';
import { h, icon, toast, basename, store } from './util.js';
import * as Explorer from './views/explorer.js';
import * as Sessions from './views/sessions.js';
import * as Editor from './views/editor.js';
import * as Bottom from './views/bottom.js';
import * as Chat from './views/chat.js';
import * as Models from './views/models.js';
import * as Settings from './views/settings.js';
import * as Setup from './views/setup.js';

export const S = {
  rpc: null,
  info: null,
  settings: null,
  secretsSet: [],
  model: { state: 'idle' },
  usage: null,
  git: null,
};
window.S = S;

const token = new URLSearchParams(location.hash.slice(1)).get('token') || sessionStorage.getItem('feride.token');
if (token) sessionStorage.setItem('feride.token', token);
history.replaceState(null, '', location.pathname); // jetonu adres çubuğundan kaldır

window.ferideOpenUrl = (url) => S.rpc.call('app.open_url', { url }).catch((e) => toast(e.message, 'err'));

// ---------------------------------------------------------------- yan paneller
const SIDE = {
  explorer: { icon: 'files', title: 'Gezgin', mod: Explorer },
  sessions: { icon: 'chat', title: 'Sohbetler', mod: Sessions },
};
const PAGES = [
  { id: 'models', icon: 'cpu', title: 'Model Merkezi', open: () => Models.open() },
  { id: 'settings', icon: 'settings', title: 'Ayarlar', open: () => Settings.open() },
  { id: 'setup', icon: 'wrench', title: 'Kurulum ve Tanılama', open: () => Setup.open() },
];
let currentSide = SIDE[store('side')] ? store('side') : 'explorer'; // kaldırılmış paneller (ör. eski "Ara") gezgine döner

function renderActivityBar() {
  const bar = document.getElementById('activitybar');
  bar.innerHTML = '';
  for (const [id, v] of Object.entries(SIDE)) {
    bar.append(h('button', { class: `icon-btn ${currentSide === id ? 'active' : ''}`, title: v.title, onclick: () => showSide(id) }, icon(v.icon)));
  }
  bar.append(h('div', { class: 'spacer' }));
  for (const p of PAGES) bar.append(h('button', { class: 'icon-btn', title: p.title, onclick: p.open }, icon(p.icon)));
}

export function showSide(id) {
  const panel = document.getElementById('sidepanel');
  if (currentSide === id && !panel.classList.contains('hidden')) {
    panel.classList.add('hidden');
    document.querySelector('.resizer-x[data-target=sidepanel]').classList.add('hidden');
    currentSide = null;
  } else {
    currentSide = id;
    panel.classList.remove('hidden');
    document.querySelector('.resizer-x[data-target=sidepanel]').classList.remove('hidden');
    panel.innerHTML = '';
    SIDE[id].mod.render(panel);
  }
  store('side', currentSide);
  renderActivityBar();
}

// ---------------------------------------------------------------- üst çubuk
export function renderTopbar() {
  const ws = document.getElementById('ws-chip');
  ws.innerHTML = '';
  ws.append(icon('folder'), h('span', { class: 'nowrap' }, basename(S.info?.workspace || '') || 'Klasör seç'));
  ws.onclick = () => Explorer.pickWorkspace();

  // Model seçici ve izin modu mesaj kutusunun altında (chat.js > renderFoot).
  const tb = document.getElementById('theme-btn');
  tb.innerHTML = '';
  tb.append(icon(S.settings?.theme === 'light' ? 'moon' : 'sun'));
  tb.onclick = () => saveSettings({ theme: S.settings?.theme === 'light' ? 'dark' : 'light' });
  const fb = document.getElementById('focus-btn');
  fb.innerHTML = '';
  fb.append(icon('maximize'));
  fb.onclick = toggleFocus;
}

function toggleFocus() {
  document.body.classList.toggle('focus-chat');
  store('focus', document.body.classList.contains('focus-chat'));
  Editor.refresh();
}

function applyTheme() {
  const t = S.settings?.theme === 'light' ? 'light' : 'dark';
  document.documentElement.dataset.theme = t;
  document.getElementById('hljs-theme').href = `vendor/hljs/${t === 'light' ? 'github' : 'github-dark'}.min.css`;
  Bottom.applyTheme?.();
}

// ---------------------------------------------------------------- durum çubuğu
export function renderStatusbar() {
  const sb = document.getElementById('statusbar');
  sb.innerHTML = '';
  const conn = S.rpc?.connected;
  sb.append(h('span', { class: 'item' }, h('span', { class: `dot ${conn ? 'ok' : 'err'}` }), conn ? 'Bağlı' : 'Bağlantı yok'));
  if (S.git?.is_repo) {
    const ch = S.git.changes?.length || 0;
    sb.append(h('span', { class: 'item click', title: 'Git', onclick: () => showSide('explorer') }, icon('git'), S.git.branch || '?', ch ? ` • ${ch} değişiklik` : ''));
  }
  sb.append(h('span', { class: 'item', title: 'Ajan kabuğu' }, icon('terminal'), S.info?.shell || ''));
  const spacer = h('span', { class: 'spacer' });
  sb.append(spacer);
  if (S.model?.state === 'ready') {
    if (S.model.placement) sb.append(h('span', { class: 'item', title: S.model.summary || '' }, icon('cpu'), placementLabel(S.model.placement)));
    if (S.model.ctx) sb.append(h('span', { class: 'item' }, `Bağlam ${Math.round(S.model.ctx / 1024)}K`));
  }
  if (S.usage?.prompt_tokens && S.usage?.ctx) {
    const pct = Math.round((S.usage.prompt_tokens / S.usage.ctx) * 100);
    sb.append(h('span', { class: 'item', title: 'Son istekte kullanılan bağlam' }, `Doluluk %${pct}`));
  }
  const tps = S.usage?.turn?.tps ?? S.usage?.tps;
  if (tps) sb.append(h('span', { class: 'item', title: 'Son turun ortalama üretim hızı' }, icon('zap'), `${tps.toFixed(1).replace('.', ',')} token/sn`));
  sb.append(h('span', { class: 'item' }, `FerIDE ${S.info?.display_version || ''}`));
}

export function placementLabel(p) {
  return { gpu: 'Tamamı GPU', mixed: 'GPU + RAM', 'moe-cpu': 'MoE: uzmanlar RAM', cpu: 'Yalnızca CPU' }[p] || p;
}

// ---------------------------------------------------------------- ayarlar
export async function loadSettings() {
  const r = await S.rpc.call('settings.get');
  S.settings = r.settings;
  S.secretsSet = r.secrets_set;
  applyTheme();
  renderTopbar();
}

export async function saveSettings(patch) {
  try {
    S.settings = await S.rpc.call('settings.set', { patch });
    applyTheme();
    renderTopbar();
    Chat.updateHint?.();
    return S.settings;
  } catch (e) {
    toast(`Ayar kaydedilemedi: ${e.message}`, 'err');
    throw e;
  }
}

export async function refreshInfo() {
  S.info = await S.rpc.call('app.info');
  renderTopbar();
  renderStatusbar();
}

export async function refreshGit() {
  try { S.git = await S.rpc.call('fs.git_status'); } catch { S.git = null; }
  renderStatusbar();
}

// ---------------------------------------------------------------- boyutlandırıcılar
function setupResizers() {
  document.querySelectorAll('.resizer-x').forEach((r) => {
    const target = document.getElementById(r.dataset.target);
    const dir = Number(r.dataset.dir);
    const saved = store(`w.${r.dataset.target}`);
    if (saved) target.style.width = `${saved}px`;
    r.addEventListener('mousedown', (e) => {
      e.preventDefault();
      const startX = e.clientX;
      const startW = target.getBoundingClientRect().width;
      r.classList.add('drag');
      const move = (ev) => { target.style.width = `${Math.max(160, startW + (ev.clientX - startX) * dir)}px`; Editor.refresh(); Bottom.fit?.(); };
      const up = () => { r.classList.remove('drag'); removeEventListener('mousemove', move); removeEventListener('mouseup', up); store(`w.${r.dataset.target}`, target.getBoundingClientRect().width); };
      addEventListener('mousemove', move);
      addEventListener('mouseup', up);
    });
  });
  const ry = document.querySelector('.resizer-y');
  const bp = document.getElementById('bottompanel');
  const savedH = store('h.bottom');
  if (savedH) bp.style.height = `${savedH}px`;
  ry.addEventListener('mousedown', (e) => {
    e.preventDefault();
    const startY = e.clientY;
    const startH = bp.getBoundingClientRect().height;
    ry.classList.add('drag');
    const move = (ev) => { bp.style.height = `${Math.max(80, startH - (ev.clientY - startY))}px`; Editor.refresh(); Bottom.fit?.(); };
    const up = () => { ry.classList.remove('drag'); removeEventListener('mousemove', move); removeEventListener('mouseup', up); store('h.bottom', bp.getBoundingClientRect().height); };
    addEventListener('mousemove', move);
    addEventListener('mouseup', up);
  });
}

function setupShortcuts() {
  addEventListener('keydown', (e) => {
    const mod = e.ctrlKey || e.metaKey;
    if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); Editor.saveActive(); }
    else if (mod && e.key.toLowerCase() === 'j') { e.preventDefault(); toggleFocus(); }
    else if (mod && e.key === '`') { e.preventDefault(); Bottom.toggle(); }
    else if (mod && e.key.toLowerCase() === 'l') { e.preventDefault(); Chat.focusComposer(); }
    else if (mod && e.key.toLowerCase() === 'n' && e.shiftKey) { e.preventDefault(); Chat.newChat(); }
    else if (mod && e.key.toLowerCase() === 'v' && e.shiftKey) { e.preventDefault(); import('./views/live.js').then((l) => (l.isActive() ? l.close() : l.open())); }
  });
}

// ---------------------------------------------------------------- başlangıç
async function boot() {
  if (!token) {
    document.body.innerHTML = '<div class="empty" style="padding-top:20vh"><h2>FerIDE</h2>Bu sayfa jetonsuz açılamaz. FerIDE uygulamasını başlatın.</div>';
    return;
  }
  if (store('focus')) document.body.classList.add('focus-chat');
  S.rpc = new Rpc(token);
  S.rpc.on('_connection', ({ connected }) => {
    renderStatusbar();
    if (connected && S.info) { refreshInfo(); Chat.reloadCurrent?.(); }
  });
  await S.rpc.connect();
  await loadSettings();
  await refreshInfo();
  S.model = await S.rpc.call('models.status');
  renderTopbar();

  S.rpc.on('model.status', (st) => { S.model = st; renderTopbar(); renderStatusbar(); Models.onStatus?.(st); Chat.updateHint?.(); });
  S.rpc.on('settings.changed', (s) => { S.settings = s; applyTheme(); renderTopbar(); Chat.updateHint?.(); });
  S.rpc.on('agent', (ev) => {
    if (ev.kind === 'usage') { S.usage = ev; renderStatusbar(); }
    if (ev.kind === 'done') refreshGit();
    Chat.onAgentEvent(ev);
    Sessions.onAgentEvent?.(ev);
  });

  renderActivityBar();
  setupResizers();
  setupShortcuts();
  Editor.init(document.getElementById('tabs'), document.getElementById('editor-area'));
  Bottom.init(document.getElementById('bottompanel'));
  Chat.init(document.getElementById('agentpanel'));
  if (currentSide && SIDE[currentSide]) { const c = currentSide; currentSide = null; showSide(c); }
  else { document.getElementById('sidepanel').classList.add('hidden'); }
  renderStatusbar();
  refreshGit();
  setInterval(refreshGit, 20000);

  if (S.info.needs_setup) Setup.open(true);
  else Editor.showWelcome();
  if (S.info.smart_app_control === 1) showSacNotice();
}

// Windows Akıllı Uygulama Denetimi imzasız llama.cpp'yi engelliyor: açılışta bir kez açıkla.
async function showSacNotice() {
  try {
    const r = await S.rpc.call('setup.status');
    const { modal } = await import('./util.js');
    const m = modal({
      title: 'Windows, FerIDE\'nin model motorunu engelliyor',
      body: Setup.sacWarning(r.sac_help),
      actions: [{ label: 'Tamam' }],
    });
    m.el.style.width = 'min(640px, 94vw)';
  } catch { /* yoksay */ }
}

boot().catch((e) => {
  console.error(e);
  toast(`Başlatılamadı: ${e.message}`, 'err', 10000);
});
