// Alt panel: terminaller, model günlüğü, arka plan işlemleri.
import { S } from '../app.js';
import { h, icon, toast, basename, store } from '../util.js';

let panel;
let body;
let current = 'terminal';
const terms = []; // {id, title, term, fit, el}
let activeTerm = null;
let logEl = null;
let unsubLog = null;
const early = new Map();

export function init(el) {
  panel = el;
  if (store('bottom.hidden') !== false) { panel.classList.add('hidden'); document.querySelector('.resizer-y').classList.add('hidden'); }
  render();
  S.rpc.on('term.data', ({ id, data }) => {
    const bin = atob(data);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const t = terms.find((x) => x.id === id);
    // Sekme henüz hazır değilse (açılış istemi) tamponla.
    if (!t) { if (!early.has(id)) early.set(id, []); early.get(id).push(bytes); return; }
    t.term.write(bytes);
  });
  S.rpc.on('term.exit', ({ id }) => {
    const t = terms.find((x) => x.id === id);
    if (t) t.term.write('\r\n\x1b[90m[süreç sonlandı]\x1b[0m\r\n');
  });
  new ResizeObserver(() => fit()).observe(panel);
}

export function toggle() {
  const hidden = panel.classList.toggle('hidden');
  document.querySelector('.resizer-y').classList.toggle('hidden', hidden);
  store('bottom.hidden', hidden);
  if (!hidden && current === 'terminal' && !terms.length) openTerminal();
  setTimeout(fit, 30);
}

function show() {
  panel.classList.remove('hidden');
  document.querySelector('.resizer-y').classList.remove('hidden');
  store('bottom.hidden', false);
}

function render() {
  panel.innerHTML = '';
  const tab = (id, label) => h('span', { class: `ptab ${current === id ? 'active' : ''}`, onclick: () => { current = id; render(); } }, label);
  const head = h('div', { class: 'panel-head' },
    tab('terminal', 'Terminal'), tab('log', 'Model günlüğü'), tab('procs', 'Arka plan işlemleri'),
    h('span', { class: 'spacer' }));
  if (current === 'terminal') {
    for (const t of terms) {
      head.append(h('span', { class: `ptab ${t === activeTerm ? 'active' : ''}`, onclick: () => { activeTerm = t; render(); } }, t.title,
        h('span', { style: { marginLeft: '6px', cursor: 'pointer' }, title: 'Kapat', onclick: (e) => { e.stopPropagation(); closeTerm(t); } }, '×')));
    }
    head.append(h('button', { class: 'icon-btn', title: 'Yeni terminal', onclick: () => openTerminal() }, icon('plus')));
  }
  head.append(h('button', { class: 'icon-btn', title: 'Paneli gizle', onclick: toggle }, icon('x')));
  body = h('div', { class: 'term-host', style: { display: 'flex', flexDirection: 'column' } });
  panel.append(head, body);
  if (unsubLog) { unsubLog(); unsubLog = null; }
  if (current === 'terminal') {
    if (activeTerm) { body.append(activeTerm.el); setTimeout(() => { fit(); activeTerm.term.focus(); }, 20); }
    else body.append(h('div', { class: 'empty' }, h('button', { class: 'btn', onclick: () => openTerminal() }, icon('terminal'), 'Terminal aç')));
  } else if (current === 'log') {
    logEl = h('div', { class: 'logbox', style: { flex: 1, maxHeight: 'none', margin: '6px', border: 0 } });
    body.append(logEl);
    S.rpc.call('models.logs').then((lines) => { logEl.textContent = lines.join('\n'); logEl.scrollTop = logEl.scrollHeight; });
    unsubLog = S.rpc.on('model.log', ({ line }) => {
      logEl.textContent += `\n${line}`;
      if (logEl.textContent.length > 300000) logEl.textContent = logEl.textContent.slice(-200000);
      logEl.scrollTop = logEl.scrollHeight;
    });
  } else {
    const box = h('div', { style: { padding: '8px 12px', overflow: 'auto' } });
    body.append(box);
    S.rpc.call('proc.list').then((list) => {
      if (!list.length) { box.append(h('div', { class: 'muted' }, 'Ajanın arka planda başlattığı işlem yok.')); return; }
      const tbl = h('table', { class: 'tbl' }, h('tr', {}, h('th', {}, 'Kimlik'), h('th', {}, 'Komut'), h('th', {}, 'Durum'), h('th')));
      for (const p of list) {
        tbl.append(h('tr', {}, h('td', { class: 'mono' }, p.id), h('td', { class: 'mono small' }, p.command), h('td', {}, p.running ? h('span', { class: 'badge ok' }, 'çalışıyor') : h('span', { class: 'badge' }, `bitti (${p.exit_code ?? '?'})`)),
          h('td', {}, p.running ? h('button', { class: 'btn sm danger', onclick: async () => { await S.rpc.call('proc.kill', { id: p.id }); render(); } }, 'Durdur') : null)));
      }
      box.append(tbl);
    });
  }
}

function termTheme() {
  const css = getComputedStyle(document.documentElement);
  const light = document.documentElement.dataset.theme === 'light';
  return {
    background: css.getPropertyValue('--bg').trim(),
    foreground: css.getPropertyValue('--fg').trim(),
    cursor: css.getPropertyValue('--accent-2').trim(),
    selectionBackground: light ? '#c7d2fe' : '#3b3f63',
  };
}

export function applyTheme() { for (const t of terms) t.term.options.theme = termTheme(); }

export async function openTerminal(cwd) {
  show();
  current = 'terminal';
  const el = h('div', { style: { flex: 1, minHeight: 0, height: '100%' } });
  const term = new Terminal({ fontFamily: getComputedStyle(document.documentElement).getPropertyValue('--mono'), fontSize: 13, cursorBlink: true, theme: termTheme(), allowProposedApi: true, scrollback: 5000 });
  const fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  let id;
  try {
    id = await S.rpc.call('term.open', { cwd: cwd || S.info?.workspace, cols: 100, rows: 24 });
  } catch (e) { toast(`Terminal açılamadı: ${e.message}`, 'err'); return; }
  const t = { id, title: basename(cwd || S.info?.workspace || '') || 'terminal', term, fit: fitAddon, el };
  term.onData((d) => S.rpc.call('term.write', { id, data: d }).catch(() => {}));
  term.onResize(({ cols, rows }) => S.rpc.call('term.resize', { id, cols, rows }).catch(() => {}));
  terms.push(t);
  activeTerm = t;
  render();
  term.open(el);
  for (const b of early.get(id) || []) term.write(b);
  early.delete(id);
  setTimeout(() => { fit(); term.focus(); }, 50);
}

function closeTerm(t) {
  S.rpc.call('term.close', { id: t.id }).catch(() => {});
  t.term.dispose();
  terms.splice(terms.indexOf(t), 1);
  activeTerm = terms[terms.length - 1] || null;
  render();
}

export function fit() {
  if (activeTerm && !panel.classList.contains('hidden') && current === 'terminal') {
    try { activeTerm.fit.fit(); } catch { /* görünmüyor */ }
  }
}

export function showLog() { show(); current = 'log'; render(); }
