// Tarayıcı paneli: FerIDE'nin kontrol ettiği gerçek tarayıcının canlı görüntüsü. Fare ve klavye girdisi etkin sekmeye
// iletilir; "Kontrolü al" ajanı bekletir. Hesap girişleri için tarayıcı ayrı, kontrolsüz bir pencerede açılır.
import { S } from '../app.js';
import { h, icon, toast } from '../util.js';
import * as Editor from './editor.js';

let root = null;
let st = null;
let frame = { w: 0, h: 0 };
let img = null;
let urlIn = null;
let bar = null;
let waitEl = null;
let overlay = null;
let stage = null;
let waitCard = null;
let unsubs = [];
let visible = false;

export function open() {
  const t = Editor.openPage('page:browser', 'Tarayıcı', 'globe', render);
  if (!t.onShow) {
    t.onShow = () => setVisible(true);
    t.onHide = () => setVisible(false);
    t.onClose = () => {
      setVisible(false);
      unsubs.forEach((u) => u());
      unsubs = [];
      root = null;
    };
  }
  setVisible(true);
  return t;
}

/** Ajan tarayıcıyı kullanmaya başlayınca paneli aç (zaten açıksa dokunma). */
export function ensureOpen() {
  if (!root?.isConnected) open();
}

function setVisible(on) {
  visible = on;
  if (root) S.rpc.call('browser.view', { on }).catch(() => {});
}

const call = (m, p) => S.rpc.call(m, p).catch((e) => { toast(e.message, 'err', 6000); throw e; });
const nav = (action) => call('browser.nav', { action }).catch(() => {});
const login = () => call('browser.login', { url: '' }).then(() => toast('Giriş penceresi açıldı. Hesaplarınıza girin, sonra o pencereyi kapatın.', 'ok', 7000)).catch(() => {});

function go() {
  const u = urlIn.value.trim();
  if (u) call('browser.open', { url: u }).catch(() => {});
}

async function render(el) {
  root = el;
  el.innerHTML = '';
  el.classList.add('browser-page');
  unsubs.forEach((u) => u());
  unsubs = [
    S.rpc.on('browser.status', (s) => { st = s; renderBar(); }),
    S.rpc.on('browser.frame', (f) => onFrame(f)),
    S.rpc.on('agent', (ev) => {
      if (ev.kind === 'approval' && ev.wait) waitCard = ev;
      else if ((ev.kind === 'approval_resolved' && waitCard?.id === ev.id) || ev.kind === 'done') waitCard = null;
      else return;
      renderWait();
    }),
  ];
  urlIn = h('input', {
    type: 'text', class: 'grow', placeholder: 'Adres ya da arama', spellcheck: 'false',
    onkeydown: (e) => { e.stopPropagation(); if (e.key === 'Enter') go(); },
  });
  bar = h('div', { class: 'bbar' });
  waitEl = h('div', { class: 'bwait hidden' });
  img = h('img', { class: 'bshot', draggable: 'false', alt: '' });
  overlay = h('div', { class: 'boverlay' });
  stage = h('div', { class: 'bstage', tabindex: '0', title: 'Tıklayıp yazabilirsiniz; girdiniz tarayıcıya gider' }, img, overlay);
  wireInput();
  el.append(
    h('div', { class: 'btop' },
      h('button', { class: 'icon-btn', title: 'Geri', onclick: () => nav('back') }, icon('arrowL')),
      h('button', { class: 'icon-btn', title: 'İleri', onclick: () => nav('forward') }, icon('arrowR')),
      h('button', { class: 'icon-btn', title: 'Yenile', onclick: () => nav('reload') }, icon('refresh')),
      urlIn,
      h('button', { class: 'btn sm', onclick: go }, 'Git')),
    bar, waitEl, stage);
  st = await S.rpc.call('browser.status').catch(() => null);
  renderBar();
  renderWait();
  if (visible) S.rpc.call('browser.view', { on: true }).catch(() => {});
}

function renderBar() {
  if (!bar || !st) return;
  bar.innerHTML = '';
  const ready = st.state === 'ready';
  const active = (st.tabs || []).find((t) => t.active);
  if (active && document.activeElement !== urlIn) urlIn.value = active.url === 'about:blank' ? '' : active.url;
  if (ready) {
    for (const t of st.tabs || []) {
      bar.append(h('span', { class: `btab ${t.active ? 'active' : ''}`, title: t.url, onclick: () => call('browser.switch', { id: t.id }).catch(() => {}) },
        h('span', { class: 'nowrap' }, t.title || t.url || 'Yeni sekme'),
        h('button', { class: 'icon-btn', title: 'Sekmeyi kapat', onclick: (e) => { e.stopPropagation(); call('browser.close_tab', { id: t.id }).catch(() => {}); } }, icon('x'))));
    }
  }
  bar.append(h('span', { class: 'spacer' }));
  if (st.agent) bar.append(h('span', { class: 'badge accent nowrap', style: { maxWidth: '360px' }, title: st.agent }, icon('sparkles'), st.agent));
  if (ready) {
    bar.append(
      h('button', { class: `btn sm ${st.user_control ? 'primary' : ''}`, title: st.user_control ? 'Ajan devam edebilsin' : 'Ajanı beklet; tarayıcıyı siz kullanın', onclick: () => call('browser.control', { user: !st.user_control }).catch(() => {}) },
        icon('hand'), st.user_control ? 'Ajana bırak' : 'Kontrolü al'),
      h('button', { class: 'btn sm ghost', title: 'Gerçek tarayıcı penceresini öne getir', onclick: () => call('browser.front').catch(() => {}) }, icon('external'), 'Pencere'));
  }
  if (st.state !== 'login') bar.append(h('button', { class: 'btn sm ghost', title: 'Hesaplarınıza (Google vb.) sıradan bir pencerede girin', onclick: login }, icon('login'), 'Hesaplarıma giriş yap'));
  if (ready) bar.append(h('button', { class: 'icon-btn', title: 'Tarayıcıyı kapat (oturumlar kalır)', onclick: () => call('browser.close').catch(() => {}) }, icon('power')));
  stage.classList.toggle('agent', !!st.agent);
  renderOverlay();
}

function renderOverlay() {
  overlay.innerHTML = '';
  const ready = st?.state === 'ready';
  overlay.classList.toggle('hidden', ready && !!img.getAttribute('src'));
  if (ready) {
    overlay.append(h('div', { class: 'muted' }, icon('loader', 'spin'), ' Görüntü bekleniyor…'));
    return;
  }
  if (st?.state === 'starting') {
    overlay.append(h('div', {}, icon('loader', 'spin'), ` ${st.name || 'Tarayıcı'} açılıyor…`));
    return;
  }
  if (st?.state === 'login') {
    overlay.append(h('div', { class: 'col', style: { maxWidth: '520px', alignItems: 'center' } },
      icon('login'),
      h('h3', { style: { margin: '4px 0' } }, 'Giriş penceresi açık'),
      h('div', {}, `${st.name || 'Tarayıcı'} ayrı bir pencerede, uzaktan kontrol olmadan açıldı. Hesaplarınıza orada girin (şifre ve iki adımlı doğrulama sizde kalır), sonra o pencereyi kapatın. Oturumlar FerIDE profilinde kalır; ajan tarayıcıyı ondan sonra kullanabilir.`)));
    return;
  }
  overlay.append(h('div', { class: 'col', style: { maxWidth: '560px', alignItems: 'center' } },
    icon('globe'),
    h('h3', { style: { margin: '4px 0' } }, 'Tarayıcı kapalı'),
    h('div', {}, 'Ajan gerektiğinde tarayıcıyı kendisi açar. FerIDE\'ye ayrılmış bir profil kullanılır; kişisel tarayıcınız etkilenmez.'),
    st?.error ? h('div', { class: 'error-box' }, st.error) : null,
    h('div', { class: 'row', style: { marginTop: '8px', flexWrap: 'wrap', justifyContent: 'center' } },
      h('button', { class: 'btn primary', onclick: () => call('browser.start').catch(() => {}) }, icon('play'), 'Tarayıcıyı aç'),
      h('button', { class: 'btn', onclick: login }, icon('login'), 'Hesaplarıma giriş yap')),
    h('div', { class: 'small muted', style: { marginTop: '6px' } }, 'Google gibi bazı siteler uzaktan kontrol edilen tarayıcıda girişe izin vermez; "Hesaplarıma giriş yap" tarayıcıyı aynı profille sıradan bir pencerede açar.')));
}

function renderWait() {
  if (!waitEl) return;
  waitEl.innerHTML = '';
  waitEl.classList.toggle('hidden', !waitCard);
  if (!waitCard) return;
  const ev = waitCard;
  const answer = (a) => S.rpc.call('chat.approve', { session: ev.session, id: ev.id, answer: a }).catch((e) => toast(e.message, 'err'));
  waitEl.append(icon('hand'), h('span', { class: 'grow' }, h('b', {}, 'Ajan seni bekliyor: '), ev.summary),
    h('button', { class: 'btn primary sm', onclick: () => answer('allow') }, icon('check'), 'Devam et'),
    h('button', { class: 'btn sm danger', onclick: () => answer('deny') }, 'Vazgeç'));
}

function onFrame(f) {
  if (!img || !f?.data) return;
  frame = { w: Number(f.w) || 0, h: Number(f.h) || 0 };
  img.src = `data:image/jpeg;base64,${f.data}`;
  if (st?.state === 'ready') overlay.classList.add('hidden');
}

// ---------------------------------------------------------------- girdi
const BTN = ['left', 'middle', 'right'];
const mods = (e) => (e.altKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.metaKey ? 4 : 0) | (e.shiftKey ? 8 : 0);
const send = (ev) => S.rpc.call('browser.input', ev).catch(() => {});

/** Görüntüdeki nokta → sayfanın CSS pikseli. */
function pos(e) {
  const r = img.getBoundingClientRect();
  const w = frame.w || img.naturalWidth || r.width;
  const hh = frame.h || img.naturalHeight || r.height;
  return { x: ((e.clientX - r.left) / r.width) * w, y: ((e.clientY - r.top) / r.height) * hh };
}

function isText(e) {
  // AltGr ile yazılan karakterler (@, €, [ …) Ctrl+Alt olarak gelir; bunlar da metindir.
  return e.key.length === 1 && (!(e.ctrlKey || e.metaKey) || e.getModifierState('AltGraph'));
}

// Fare görüntünün dışında bırakılsa da bırakma olayı gitsin (yoksa tarayıcı düğmeyi basılı sanır).
let mouseDown = false;
addEventListener('mouseup', (e) => {
  if (!mouseDown || !img?.isConnected) return;
  mouseDown = false;
  const p = pos(e);
  send({ type: 'mouseup', x: p.x, y: p.y, button: BTN[e.button] || 'left', buttons: e.buttons, clicks: e.detail || 1, modifiers: mods(e) });
});

function wireInput() {
  let lastMove = 0;
  img.addEventListener('mousedown', (e) => {
    e.preventDefault();
    stage.focus();
    mouseDown = true;
    const p = pos(e);
    send({ type: 'mousedown', x: p.x, y: p.y, button: BTN[e.button] || 'left', buttons: e.buttons, clicks: e.detail || 1, modifiers: mods(e) });
  });
  img.addEventListener('mousemove', (e) => {
    const now = performance.now();
    if (now - lastMove < 40) return;
    lastMove = now;
    const p = pos(e);
    send({ type: 'mousemove', x: p.x, y: p.y, buttons: e.buttons, button: e.buttons & 1 ? 'left' : 'none', modifiers: mods(e) });
  });
  img.addEventListener('contextmenu', (e) => e.preventDefault());
  stage.addEventListener('wheel', (e) => {
    e.preventDefault();
    const p = pos(e);
    send({ type: 'wheel', x: p.x, y: p.y, dx: e.deltaX, dy: e.deltaY, modifiers: mods(e) });
  }, { passive: false });
  stage.addEventListener('keydown', (e) => {
    e.stopPropagation(); // FerIDE kısayolları tarayıcıdayken çalışmasın
    if (e.isComposing || e.key === 'Dead' || e.key === 'Process' || e.key === 'Unidentified') return;
    e.preventDefault();
    if (isText(e)) send({ type: 'text', text: e.key });
    else send({ type: 'keydown', key: e.key, code: e.code, keyCode: e.keyCode, modifiers: mods(e) });
  });
  stage.addEventListener('keyup', (e) => {
    e.stopPropagation();
    if (isText(e)) return;
    e.preventDefault();
    send({ type: 'keyup', key: e.key, code: e.code, keyCode: e.keyCode, modifiers: mods(e) });
  });
}
