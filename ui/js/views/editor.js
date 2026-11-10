// Düzenleyici sekmeleri (CodeMirror) ve sayfa sekmeleri (Model Merkezi, Ayarlar…).
import { S } from '../app.js';
import { h, icon, toast, basename, confirmBox } from '../util.js';
import * as Explorer from './explorer.js';
import * as Chat from './chat.js';

let tabsEl;
let areaEl;
const tabs = []; // {id, kind:'file'|'page', path, title, el, cm, dirty, render}
let active = null;

const MODES = {
  js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'jsx', ts: 'text/typescript', tsx: 'text/typescript-jsx', json: 'application/json',
  py: 'python', rs: 'rust', c: 'text/x-csrc', h: 'text/x-csrc', cpp: 'text/x-c++src', hpp: 'text/x-c++src', cc: 'text/x-c++src',
  java: 'text/x-java', kt: 'text/x-kotlin', cs: 'text/x-csharp', go: 'go', dart: 'dart', swift: 'text/x-swift',
  css: 'css', scss: 'text/x-scss', less: 'text/x-less', html: 'htmlmixed', htm: 'htmlmixed', xml: 'xml', svg: 'xml', vue: 'htmlmixed',
  md: 'markdown', markdown: 'markdown', sh: 'shell', bash: 'shell', zsh: 'shell', ps1: 'powershell', psm1: 'powershell',
  toml: 'toml', yaml: 'yaml', yml: 'yaml', sql: 'sql', ini: 'toml', cfg: 'toml', env: 'shell', dockerfile: 'shell',
};
const IMAGE = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'ico'];

export function init(tEl, aEl) {
  tabsEl = tEl;
  areaEl = aEl;
  addEventListener('beforeunload', (e) => { if (tabs.some((t) => t.dirty)) { e.preventDefault(); e.returnValue = ''; } });
}

function ext(p) {
  const n = basename(p).toLowerCase();
  if (n === 'dockerfile' || n === 'makefile') return n;
  return n.includes('.') ? n.split('.').pop() : '';
}

function renderTabs() {
  tabsEl.innerHTML = '';
  for (const t of tabs) {
    const el = h('div', { class: `tab ${t === active ? 'active' : ''}`, title: t.path || t.title, onclick: () => activate(t) },
      t.icon ? icon(t.icon) : icon('file'),
      h('span', { class: 'nowrap' }, t.title),
      t.dirty ? h('span', { class: 'dirty', title: 'Kaydedilmedi' }) : null,
      h('button', { class: 'icon-btn', title: 'Kapat', onclick: (e) => { e.stopPropagation(); close(t); } }, icon('x')));
    el.addEventListener('auxclick', (e) => { if (e.button === 1) close(t); });
    tabsEl.append(el);
  }
}

function activate(t) {
  active = t;
  for (const x of tabs) x.el.classList.toggle('hidden', x !== t);
  renderTabs();
  if (t.cm) setTimeout(() => { t.cm.refresh(); t.cm.focus(); }, 0);
  if (t.onShow) t.onShow();
}

async function close(t) {
  if (t.dirty && !(await confirmBox('Kaydedilmemiş değişiklik', `${t.title} kaydedilmeden kapatılsın mı?`, 'Kapat', true))) return;
  const i = tabs.indexOf(t);
  tabs.splice(i, 1);
  t.el.remove();
  t.onClose?.();
  if (active === t) {
    const next = tabs[i] || tabs[i - 1];
    if (next) activate(next);
    else { active = null; showWelcome(); }
  }
  renderTabs();
}

export function closePath(path) {
  const t = tabs.find((x) => x.path === path);
  if (t) { t.dirty = false; close(t); }
}

function addTab(t) {
  t.el.classList.add('page');
  areaEl.querySelector('.welcome-page')?.remove();
  areaEl.append(t.el);
  tabs.push(t);
  activate(t);
}

/** Sayfa sekmesi aç (aynı kimlikle açıksa ona geç). */
export function openPage(id, title, iconName, render) {
  let t = tabs.find((x) => x.id === id);
  if (t) { activate(t); t.render?.(); return t; }
  const el = h('div');
  t = { id, kind: 'page', title, icon: iconName, el, render: () => { el.innerHTML = ''; render(el); } };
  addTab(t);
  t.render();
  return t;
}

export async function openFile(path, line) {
  let t = tabs.find((x) => x.path === path);
  if (t) {
    activate(t);
    if (line && t.cm) jump(t.cm, line);
    return;
  }
  const e = ext(path);
  if (IMAGE.includes(e)) {
    const r = await S.rpc.call('fs.read_base64', { path }).catch((err) => { toast(err.message, 'err'); return null; });
    if (!r) return;
    const el = h('div', { style: { display: 'grid', placeItems: 'center', padding: '20px' } }, h('img', { src: `data:${r.mime};base64,${r.data}`, style: { maxWidth: '100%', maxHeight: '90vh' } }));
    addTab({ id: path, kind: 'file', path, title: basename(path), icon: 'image', el });
    return;
  }
  let file;
  try { file = await S.rpc.call('fs.read', { path }); } catch (err) { toast(err.message, 'err'); return; }
  if (file.text == null) {
    const el = h('div', { class: 'empty', style: { paddingTop: '15vh' } },
      file.too_large ? `Dosya çok büyük (${Math.round(file.size / 1048576)} MB).` : 'İkili dosya; düzenleyicide gösterilemez.',
      h('br'),
      h('button', { class: 'btn', onclick: () => S.rpc.call('app.open_path', { path }) }, icon('external'), 'Sistemde aç'),
      ' ',
      h('button', { class: 'btn', onclick: () => Chat.mention(path) }, icon('chat'), 'Ajana sor'));
    addTab({ id: path, kind: 'file', path, title: basename(path), el });
    return;
  }
  const el = h('div', { style: { height: '100%' } });
  t = { id: path, kind: 'file', path, title: basename(path), icon: 'file', el, dirty: false };
  addTab(t);
  const ed = S.settings?.editor || {};
  const cm = CodeMirror(el, {
    value: file.text,
    mode: MODES[e] || null,
    theme: 'feride',
    lineNumbers: true,
    indentUnit: ed.tab_size || 4,
    tabSize: ed.tab_size || 4,
    indentWithTabs: false,
    lineWrapping: !!ed.word_wrap,
    matchBrackets: true,
    autoCloseBrackets: true,
    styleActiveLine: true,
    extraKeys: {
      'Ctrl-S': () => save(t), 'Cmd-S': () => save(t),
      'Ctrl-/': 'toggleComment', 'Cmd-/': 'toggleComment',
      Tab: (c) => (c.somethingSelected() ? c.indentSelection('add') : c.replaceSelection(' '.repeat(c.getOption('indentUnit')))),
    },
  });
  cm.getWrapperElement().style.fontSize = `${ed.font_size || 14}px`;
  t.cm = cm;
  t.saved = file.text;
  cm.on('change', () => {
    const d = cm.getValue() !== t.saved;
    if (d !== t.dirty) { t.dirty = d; renderTabs(); }
  });
  cm.refresh();
  if (line) jump(cm, line);
}

function jump(cm, line) {
  setTimeout(() => {
    cm.setCursor({ line: line - 1, ch: 0 });
    cm.scrollIntoView({ line: line - 1, ch: 0 }, 120);
    cm.focus();
  }, 30);
}

async function save(t) {
  if (!t?.cm) return;
  const text = t.cm.getValue();
  try {
    await S.rpc.call('fs.write', { path: t.path, text });
    t.saved = text;
    t.dirty = false;
    renderTabs();
    toast(`Kaydedildi: ${t.title}`, 'ok', 1800);
  } catch (e) { toast(`Kaydedilemedi: ${e.message}`, 'err'); }
}

export function saveActive() { if (active?.kind === 'file') save(active); }

/** Ajan bir dosyayı değiştirdiyse açık sekmeyi yenile (kaydedilmemiş değişiklik yoksa). */
export async function reloadIfOpen(path) {
  const t = tabs.find((x) => x.path === path);
  if (!t?.cm || t.dirty) return;
  try {
    const f = await S.rpc.call('fs.read', { path });
    if (f.text != null && f.text !== t.cm.getValue()) {
      const pos = t.cm.getCursor();
      t.cm.setValue(f.text);
      t.saved = f.text;
      t.cm.setCursor(pos);
    }
  } catch { /* dosya silinmiş olabilir */ }
}

export function refresh() { if (active?.cm) active.cm.refresh(); }

export function showWelcome() {
  if (tabs.length || areaEl.querySelector('.welcome-page')) return;
  const card = (ic, title, text, run) => h('div', { class: 'card', onclick: run }, icon(ic), h('h3', {}, title), h('p', {}, text));
  const el = h('div', { class: 'page welcome-page' },
    h('div', { class: 'welcome' },
      h('h1', {}, h('span', { class: 'grad' }, 'FerIDE'), ' beta v5.4'),
      h('div', { class: 'muted' }, 'Yerel modellerle çalışan, kendi bilgisayarınızda kalan yapay zeka geliştirme ortamı.'),
      h('div', { class: 'cards' },
        card('folderOpen', 'Klasör aç', 'Bir proje klasörünü çalışma alanı yap.', () => Explorer.pickWorkspace()),
        card('chat', 'Feride ile konuş', 'Kod yazdır, hata ayıklat, belge hazırlat.', () => Chat.focusComposer()),
        card('cpu', 'Model Merkezi', 'Modelini seç, başlat ya da Hugging Face\'ten indir.', () => import('./models.js').then((m) => m.open())),
        card('wrench', 'Kurulum ve tanı', 'Bağımlılıkları denetle, eksikleri tek tıkla kur.', () => import('./setup.js').then((m) => m.open())),
        card('terminal', 'Terminal', 'Çalışma alanında gerçek bir terminal (Ctrl+`).', () => import('./bottom.js').then((b) => b.openTerminal())),
        card('settings', 'Ayarlar', 'İzin modu, MCP, skill, hafıza, ses.', () => import('./settings.js').then((m) => m.open()))),
      h('h3', { style: { marginTop: '28px' } }, 'Kısayollar'),
      h('div', { class: 'kv' },
        h('span', { class: 'k' }, 'Ctrl+L'), 'Sohbet kutusuna git',
        h('span', { class: 'k' }, 'Ctrl+J'), 'Sohbet odak modu',
        h('span', { class: 'k' }, 'Ctrl+`'), 'Terminali aç/kapat',
        h('span', { class: 'k' }, 'Ctrl+S'), 'Dosyayı kaydet',
        h('span', { class: 'k' }, 'Ctrl+Shift+F'), 'Çalışma alanında ara',
        h('span', { class: 'k' }, 'Ctrl+Shift+N'), 'Yeni sohbet')));
  areaEl.append(el);
}
