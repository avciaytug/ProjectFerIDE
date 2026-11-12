// FerIDE kurulum sihirbazı: program ve veri klasörünü seçme, kısayollar, kurulum.
import { Rpc } from './rpc.js';
import { h, icon, fmtBytes, debounce } from './util.js';

const token = new URLSearchParams(location.hash.slice(1)).get('token') || sessionStorage.getItem('feride.install.token');
if (token) sessionStorage.setItem('feride.install.token', token);
history.replaceState(null, '', location.pathname);

const root = document.getElementById('installer');
const st = {
  info: null,
  program: '',
  data: '',
  desktop: true,
  menu: true,
  path: true,
  launch: true,
  check: null,
  busy: false,
  error: null,
  done: null,
};
let rpc;

const MIN_FREE = 30 * 1024 ** 3; // modeller için önerilen en az boş alan

function space(s, label) {
  if (!s) return h('span', { class: 'muted' }, 'Sürücü bilgisi okunamadı');
  const low = s.free < MIN_FREE && label === 'data';
  return h('span', { class: low ? 'inst-warn' : 'muted' },
    `Bu sürücüde ${fmtBytes(s.free)} boş (toplam ${fmtBytes(s.total)})`,
    low ? ' — modeller için en az 30 GB boş alan önerilir; başka bir sürücü seçebilirsiniz.' : '');
}

const inspect = debounce(async () => {
  try {
    st.check = await rpc.call('installer.inspect', { program: st.program, data: st.data });
  } catch (e) {
    st.check = { error: e.message };
  }
  render();
}, 250);

async function pick(kind) {
  try {
    const p = await rpc.call('installer.pick', { kind, current: kind === 'data' ? st.data : st.program });
    if (p) {
      st[kind === 'data' ? 'data' : 'program'] = p;
      st.error = null;
      render();
      inspect();
    }
  } catch (e) {
    st.error = e.message;
    render();
  }
}

function pathField(kind, title, hint, extra) {
  const key = kind === 'data' ? 'data' : 'program';
  const input = h('input', {
    type: 'text', value: st[key], spellcheck: 'false', class: 'mono', 'data-key': key,
    oninput: (e) => { st[key] = e.target.value; st.error = null; inspect(); },
  });
  return h('section', { class: 'inst-card' },
    h('div', { class: 'inst-card-h' }, icon(kind === 'data' ? 'layers' : 'folder'), h('b', {}, title)),
    h('div', { class: 'small muted' }, hint),
    h('div', { class: 'inst-path' }, input,
      st.info?.can_pick ? h('button', { class: 'btn', disabled: st.busy, onclick: () => pick(kind) }, icon('folderOpen'), 'Değiştir…') : null),
    h('div', { class: 'small inst-meta' }, space(st.check?.[`${key}_space`], kind), extra || null));
}

function check(label, key, help) {
  return h('label', { class: 'check inst-opt' },
    h('input', { type: 'checkbox', checked: st[key], disabled: st.busy, onchange: (e) => { st[key] = e.target.checked; } }),
    h('span', {}, label, help ? h('span', { class: 'tiny muted' }, ` — ${help}`) : null));
}

function usePortable() {
  if (!st.info?.self_dir) return;
  st.program = st.info.self_dir;
  st.desktop = false;
  st.menu = false;
  st.path = false;
  render();
  inspect();
}

async function install() {
  st.busy = true;
  st.error = null;
  render();
  try {
    st.done = await rpc.call('installer.install', {
      program: st.program, data: st.data, desktop: st.desktop, menu: st.menu, path: st.path, launch: st.launch,
    });
    st.busy = false;
    render();
    if (st.launch) setTimeout(() => rpc.call('installer.finish', { launch: true }).catch(() => {}), 1600);
  } catch (e) {
    st.busy = false;
    st.error = e.message;
    render();
  }
}

function renderDone() {
  const i = st.done.info;
  root.append(h('div', { class: 'inst-wrap' },
    h('div', { class: 'inst-hero' }, h('div', { class: 'logo inst-ok' }, icon('check')),
      h('h1', {}, st.info.update ? 'FerIDE güncellendi' : 'FerIDE kuruldu'),
      h('div', { class: 'muted' }, st.launch ? 'FerIDE açılıyor…' : 'Kurulum tamamlandı.')),
    h('section', { class: 'inst-card' },
      h('div', { class: 'kv' },
        h('span', { class: 'k' }, 'Program'), h('span', { class: 'mono small' }, i.install_dir),
        h('span', { class: 'k' }, 'Veriler'), h('span', { class: 'mono small' }, i.data_dir)),
      ...(st.done.warnings || []).map((w) => h('div', { class: 'small inst-warn', style: { marginTop: '6px' } }, icon('alert'), ' ', w)),
      h('div', { class: 'tiny muted', style: { marginTop: '10px' } },
        st.info.os === 'windows'
          ? 'Kaldırmak için: Windows Ayarlar → Uygulamalar → FerIDE, ya da FerIDE içinde Ayarlar → Genel → FerIDE\'yi kaldır.'
          : 'Kaldırmak için: FerIDE içinde Ayarlar → Genel → FerIDE\'yi kaldır, ya da terminalde: feride uninstall')),
    h('div', { class: 'inst-actions' },
      h('span', { class: 'spacer' }),
      h('button', { class: st.info.no_launch ? 'btn primary' : 'btn', onclick: () => rpc.call('installer.finish', { launch: false }) }, 'Kapat'),
      st.info.no_launch ? null
        : h('button', { class: 'btn primary', onclick: () => rpc.call('installer.finish', { launch: true }) }, icon('play'), 'FerIDE\'yi aç'))));
}

function render() {
  // Yazarken yeniden çizim imleci kutudan düşürmesin: odak ve seçim korunur.
  const active = document.activeElement;
  const focusKey = active?.dataset?.key;
  const sel = focusKey ? [active.selectionStart, active.selectionEnd] : null;
  draw();
  if (focusKey) {
    const el = root.querySelector(`input[data-key="${focusKey}"]`);
    if (el) {
      el.focus();
      try { el.setSelectionRange(sel[0], sel[1]); } catch { /* seçim desteklenmiyor */ }
    }
  }
}

function draw() {
  root.innerHTML = '';
  if (!st.info) {
    root.append(h('div', { class: 'inst-wrap' }, h('div', { class: 'status-line' }, icon('loader', 'spin'), 'Hazırlanıyor…')));
    return;
  }
  if (st.done) {
    renderDone();
    return;
  }
  const upd = st.info.update;
  const c = st.check || {};
  const dataExtra = c.data_found
    ? h('div', { class: 'inst-found' }, icon('check'), ` Bu klasörde FerIDE verileri var (${fmtBytes(c.data_size)}): modeller, sohbetler ve ayarlar kullanılmaya devam edecek.`)
    : h('div', { class: 'tiny muted' }, 'Yeni bir klasör oluşturulur. Modeller genellikle 5–80 GB, ses paketi ~4,4 GB yer kaplar.');
  const isWin = st.info.os === 'windows';
  root.append(h('div', { class: 'inst-wrap' },
    h('div', { class: 'inst-hero' }, h('div', { class: 'logo' }, 'F'),
      h('h1', {}, upd ? 'FerIDE güncelleniyor' : 'FerIDE kurulumu'),
      h('div', { class: 'muted' }, `Sürüm ${st.info.version}. Yönetici izni gerekmez; her şey seçtiğiniz klasörlere kurulur.`)),
    pathField('program', 'Program klasörü', `FerIDE programı buraya kurulur (~25 MB). ${isWin ? 'Ör. C:\\Users\\…\\Programs\\FerIDE ya da D:\\FerIDE' : 'Ör. ~/.local/share/feride ya da /mnt/disk2/FerIDE'}.`,
      c.program_installed && !upd ? h('div', { class: 'tiny muted' }, 'Bu klasörde FerIDE kurulu; yeni sürümle güncellenir.') : null),
    pathField('data', 'Veri klasörü', 'Modeller, llama.cpp, ses paketi, sohbetler ve ayarlar burada durur. Büyüyebilir; yer azsa başka bir sürücü seçin.', dataExtra),
    h('section', { class: 'inst-card' },
      h('div', { class: 'inst-card-h' }, icon('settings'), h('b', {}, 'Seçenekler')),
      st.info.shortcuts ? check('Masaüstüne kısayol', 'desktop') : null,
      st.info.shortcuts ? check(isWin ? 'Başlat menüsüne ekle' : 'Uygulama menüsüne ekle', 'menu') : null,
      check('Komut satırından çalıştırılabilsin', 'path', isWin ? 'feride doctor, feride serve…' : '~/.local/bin/feride'),
      st.info.no_launch ? null : check('Kurulumdan sonra FerIDE\'yi aç', 'launch')),
    st.error || c.error ? h('div', { class: 'error-box' }, st.error || c.error) : null,
    h('div', { class: 'inst-actions' },
      !upd && st.info.self_dir ? h('a', { href: '#', class: 'small inst-portable', onclick: (e) => { e.preventDefault(); usePortable(); } },
        'Kurmadan, bu klasörden kullan (taşınabilir)') : h('span'),
      h('span', { class: 'spacer' }),
      h('button', { class: 'btn', disabled: st.busy, onclick: () => rpc.call('installer.finish', { launch: false }) }, 'Vazgeç'),
      h('button', { class: 'btn primary', disabled: st.busy || !!c.error || !st.program.trim() || !st.data.trim(), onclick: install },
        st.busy ? icon('loader', 'spin') : icon('download'), st.busy ? 'Kuruluyor…' : upd ? 'Güncelle' : 'Kur'))));
}

async function boot() {
  render();
  if (!token) {
    root.innerHTML = '';
    root.append(h('div', { class: 'inst-wrap' }, h('div', { class: 'error-box' }, 'Bu sayfa jetonsuz açılamaz. feride install komutunu çalıştırın.')));
    return;
  }
  rpc = new Rpc(token);
  await rpc.connect();
  st.info = await rpc.call('installer.info');
  st.program = st.info.defaults.program;
  st.data = st.info.defaults.data;
  if (st.info.existing) {
    st.desktop = st.info.existing.desktop_shortcut;
    st.menu = st.info.existing.menu_shortcut;
    st.path = st.info.existing.add_path;
  }
  if (!st.info.shortcuts) {
    st.desktop = false;
    st.menu = false;
  }
  if (st.info.no_launch) st.launch = false;
  render();
  inspect();
}

boot().catch((e) => {
  root.innerHTML = '';
  root.append(h('div', { class: 'inst-wrap' }, h('div', { class: 'error-box' }, `Kurulum sihirbazı başlatılamadı: ${e.message}`)));
});
