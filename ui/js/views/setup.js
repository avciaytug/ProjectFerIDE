// Kurulum sihirbazı ve tanılama.
import { S, refreshInfo } from '../app.js';
import { h, icon, toast, fmtBytes } from '../util.js';
import * as Editor from './editor.js';

let el = null;
let deps = [];
let state = {};
const progress = new Map();
let busy = false;
let results = null;
let firstRun = false;
let selected = new Set();
let hw = null;
let subscribed = false;

export function open(isFirstRun = false) {
  firstRun = isFirstRun;
  if (!subscribed) {
    subscribed = true;
    S.rpc.on('setup.progress', (p) => { progress.set(p.id, p); if (el?.isConnected) renderProgress(); });
    S.rpc.on('setup.done', () => load());
    S.rpc.on('setup.finished', async (r) => {
      busy = false;
      results = r.results;
      await load();
      await refreshInfo();
      const bad = r.results.filter((x) => !x.ok);
      toast(bad.length ? `Kurulum bitti; ${bad.length} adım başarısız.` : 'Kurulum tamamlandı.', bad.length ? 'warn' : 'ok', 6000);
    });
  }
  Editor.openPage('page:setup', 'Kurulum', 'wrench', (e) => { el = e; load(); });
}

async function load() {
  try {
    const r = await S.rpc.call('setup.status');
    deps = r.deps;
    state = r.state;
    sac = r.smart_app_control === 1 ? r.sac_help : null;
    if (!selected.size) for (const d of deps) if (!d.installed && (d.required || ['git', 'uv', 'node', 'pydocs', 'longpaths'].includes(d.id))) selected.add(d.id);
  } catch (e) { toast(e.message, 'err'); }
  render();
  if (!hw) S.rpc.call('app.hardware', { fresh: true }).then((x) => { hw = x; render(); }).catch(() => {});
}

let sac = null;

/** Windows Akıllı Uygulama Denetimi açıkken gösterilen uyarı (imzasız llama.cpp engellenir). */
export function sacWarning(text) {
  return h('div', { class: 'sac-warn' },
    h('div', { class: 'row', style: { alignItems: 'flex-start' } }, icon('shield'),
      h('div', { class: 'grow' },
        h('b', {}, 'Windows Akıllı Uygulama Denetimi açık'),
        h('div', { class: 'small', style: { marginTop: '4px' } }, text),
        h('div', { class: 'row', style: { marginTop: '8px' } },
          h('button', { class: 'btn primary sm', onclick: () => S.rpc.call('app.open_security').catch((e) => toast(e.message, 'err')) }, icon('external'), 'Windows Güvenlik\'i aç'),
          h('span', { class: 'tiny muted' }, 'Uygulama ve tarayıcı denetimi → Akıllı Uygulama Denetimi ayarları → Kapalı, sonra FerIDE\'yi yeniden başlatın.')))));
}

function render() {
  if (!el) return;
  el.innerHTML = '';
  const missingReq = deps.filter((d) => d.required && !d.installed);
  const adminNeeded = deps.filter((d) => selected.has(d.id) && !d.installed && d.needs_admin);
  const inner = h('div', { class: 'page-inner', style: { maxWidth: '900px' } });
  if (firstRun) {
    inner.append(h('div', { class: 'hero-setup' }, h('div', { class: 'logo' }, 'F'),
      h('h2', {}, 'FerIDE beta v5.4\'e hoş geldiniz'),
      h('div', { class: 'muted' }, 'FerIDE çalışmak için gerekenleri kendisi kurar. Her şey kullanıcı klasörünüze kurulur; yönetici izni yalnızca gerekirse ve bir kez istenir.')));
  } else {
    inner.append(h('h2', {}, 'Kurulum ve tanılama'), h('div', { class: 'muted' }, 'Bağımlılıkların durumu. Eksikleri seçip tek tıkla kurabilirsiniz.'));
  }
  if (sac) inner.append(sacWarning(sac));
  const sec = h('div', { class: 'section' });
  for (const d of deps) {
    const p = progress.get(d.id);
    const st = d.installed
      ? h('span', { class: 'badge ok' }, icon('check'), d.version ? d.version.slice(0, 40) : 'Kurulu')
      : h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: selected.has(d.id), disabled: d.required || busy, onchange: (e) => { e.target.checked ? selected.add(d.id) : selected.delete(d.id); render(); } }), d.required ? 'Gerekli' : 'Kur');
    sec.append(h('div', { class: `dep ${d.installed ? 'ok' : 'miss'}` },
      h('div', { class: 'ic' }, icon(d.installed ? 'check' : d.required ? 'alert' : 'download')),
      h('div', { class: 'grow' },
        h('div', { class: 'row' }, h('b', {}, d.name), d.needs_admin && !d.installed ? h('span', { class: 'badge warn' }, 'yönetici') : null, h('span', { class: 'tiny muted' }, d.size_hint)),
        h('div', { class: 'small muted' }, d.description),
        d.path ? h('div', { class: 'mono tiny muted nowrap' }, d.path) : null,
        p && !d.installed ? h('div', { class: 'col', style: { marginTop: '6px', gap: '4px' }, 'data-prog': d.id }, progLine(p)) : null),
      st));
  }
  inner.append(sec);
  const missingSel = deps.filter((d) => !d.installed && (selected.has(d.id) || d.required));
  inner.append(h('div', { class: 'row', style: { marginTop: '14px' } },
    busy ? h('span', { class: 'status-line' }, icon('loader', 'spin'), 'Kuruluyor… (pencereyi kapatmayın)') : null,
    adminNeeded.length && !busy ? h('span', { class: 'small', style: { color: 'var(--warn)' } }, icon('shield'), ` ${adminNeeded.map((d) => d.name).join(', ')} için tek seferlik yönetici onayı istenecek.`) : null,
    h('span', { class: 'spacer' }),
    firstRun && !missingReq.length ? h('button', { class: 'btn', onclick: async () => { await S.rpc.call('setup.skip'); firstRun = false; Editor.showWelcome(); toast('Hazırsınız!', 'ok'); render(); } }, 'Şimdilik geç') : null,
    h('button', { class: 'btn primary', disabled: busy || !missingSel.length, onclick: install }, icon('download'), missingSel.length ? `Seçilenleri kur (${missingSel.length})` : 'Her şey kurulu')));
  if (results) {
    inner.append(h('div', { class: 'section' }, h('div', { class: 'sh' }, h('h3', {}, 'Son kurulum')),
      results.map((r) => h('div', { class: 'row small', style: { padding: '3px 0', alignItems: 'flex-start' } }, r.ok ? h('span', { class: 'badge ok' }, '✓') : h('span', { class: 'badge err' }, '✗'), h('b', {}, r.id), h('span', { style: { whiteSpace: 'pre-wrap' } }, r.message)))));
  }
  if (hw) {
    inner.append(h('div', { class: 'section' }, h('div', { class: 'sh' }, icon('cpu'), h('h3', {}, 'Donanım')),
      h('div', { class: 'kv' },
        h('span', { class: 'k' }, 'İşlemci'), `${hw.cpu_name} • ${hw.physical_cores} fiziksel çekirdek`,
        h('span', { class: 'k' }, 'RAM'), `${fmtBytes(hw.ram_total_bytes)} (${fmtBytes(hw.ram_available_bytes)} boş)`,
        ...hw.gpus.flatMap((g) => [h('span', { class: 'k' }, g.id), `${g.name} — ${fmtBytes(g.total_bytes)} (${fmtBytes(g.free_bytes)} boş)${hw.unified_memory ? (hw.dedicated_gpu_bytes >= 2 ** 31 ? ` • ${fmtBytes(hw.dedicated_gpu_bytes)} ayrılmış, kalanı paylaşımlı` : ' • paylaşımlı bellek') : ''}`]),
        hw.gpus.length ? null : h('span', { class: 'k' }, 'GPU'), hw.gpus.length ? null : 'Bulunamadı (llama.cpp kurulduktan sonra ölçülür)',
        h('span', { class: 'k' }, 'Sistem'), hw.os)));
  }
  inner.append(h('div', { class: 'section' }, h('div', { class: 'sh' }, icon('info'), h('h3', {}, 'Komut satırı')),
    h('div', { class: 'small muted' }, 'Aynı tanı ve kurulum komut satırından da yapılabilir:'),
    h('pre', { class: 'logbox', style: { marginTop: '6px' } }, 'feride doctor\nferide setup llama git uv node pydocs\nferide serve --open')));
  el.append(inner);
}

function progLine(p) {
  const pct = p.total ? Math.round((p.done / p.total) * 100) : null;
  return [
    h('div', { class: 'tiny muted' }, p.message, pct !== null ? ` • ${fmtBytes(p.done)} / ${fmtBytes(p.total)}` : ''),
    pct !== null ? h('div', { class: 'progress' }, h('div', { style: { width: `${pct}%` } })) : null,
  ];
}

function renderProgress() {
  for (const [id, p] of progress) {
    const box = el.querySelector(`[data-prog="${id}"]`);
    if (box) { box.innerHTML = ''; box.append(...progLine(p).filter(Boolean)); }
    else render();
  }
}

async function install() {
  busy = true;
  results = null;
  render();
  const ids = deps.filter((d) => !d.installed && (selected.has(d.id) || d.required)).map((d) => d.id);
  try { await S.rpc.call('setup.install', { ids }); } catch (e) { busy = false; toast(e.message, 'err'); render(); }
}
