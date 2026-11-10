// Model Merkezi: yerel modeller, başlatma planı, Hugging Face'ten indirme, sağlayıcı.
import { S, saveSettings, placementLabel } from '../app.js';
import { h, icon, toast, fmtBytes, basename, confirmBox, relTime, debounce } from '../util.js';
import * as Editor from './editor.js';
import * as Bottom from './bottom.js';

let pageEl = null;
let models = [];
let downloads = new Map();
let hubState = { query: '', results: [], repo: null, files: [], loading: false };
let unsubs = [];

export function open() {
  Editor.openPage('page:models', 'Model Merkezi', 'cpu', render);
}

export function onStatus() {
  if (pageEl?.isConnected) renderStatus();
}

async function render(el) {
  pageEl = el;
  unsubs.forEach((u) => u());
  unsubs = [
    S.rpc.on('download.progress', (d) => { downloads.set(d.id, d); renderDownloads(); }),
    S.rpc.on('models.changed', () => loadModels()),
  ];
  el.innerHTML = '';
  const inner = h('div', { class: 'page-inner' },
    h('div', { class: 'row' }, h('h2', { class: 'grow' }, 'Model Merkezi'),
      h('button', { class: 'btn', onclick: () => S.rpc.call('app.open_path', { path: 'models' }) }, icon('folder'), 'Model klasörü'),
      h('button', { class: 'btn', onclick: () => Bottom.showLog() }, icon('terminal'), 'Günlük')),
    h('div', { class: 'muted' }, 'Modeller bu bilgisayarda çalışır; FerIDE belleği ölçer ve sığmayan yapılandırmayı başlatmaz.'),
    h('div', { id: 'm-status' }),
    h('div', { class: 'grid2' }, h('div', { id: 'm-local' }), h('div', { id: 'm-run' })),
    h('div', { id: 'm-downloads' }),
    h('div', { id: 'm-hub' }),
    h('div', { id: 'm-provider' }));
  el.append(inner);
  renderStatus();
  renderRun();
  renderProvider();
  renderHub();
  await loadModels();
  for (const d of await S.rpc.call('hub.downloads')) downloads.set(d.id, d);
  renderDownloads();
}

function $(id) { return pageEl?.querySelector(`#${id}`); }

function renderStatus() {
  const box = $('m-status');
  if (!box) return;
  const st = S.model || {};
  box.innerHTML = '';
  const dot = { ready: 'ok', starting: 'warn', stopping: 'warn', failed: 'err' }[st.state] || '';
  const label = { ready: 'Çalışıyor', starting: 'Yükleniyor', stopping: 'Durduruluyor', failed: 'Başlatılamadı', idle: 'Durdu' }[st.state] || st.state;
  const sec = h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('span', { class: `dot ${dot}` }), h('h3', { class: 'grow' }, st.model_name || (S.settings?.model?.selected ? basename(S.settings.model.selected) : 'Model seçilmedi')), h('span', { class: `badge ${dot}` }, label),
      st.state === 'ready' || st.state === 'starting'
        ? h('button', { class: 'btn danger sm', onclick: async () => { await S.rpc.call('models.stop'); } }, icon('stop'), 'Durdur')
        : S.settings?.model?.selected ? h('button', { class: 'btn primary sm', onclick: () => start(S.settings.model.selected) }, icon('play'), 'Başlat') : null));
  if (st.summary) sec.append(h('div', {}, st.summary));
  if (st.state === 'ready') {
    sec.append(h('div', { class: 'row small muted', style: { marginTop: '6px', flexWrap: 'wrap' } },
      h('span', { class: 'badge accent' }, placementLabel(st.placement)),
      h('span', { class: 'badge' }, `Bağlam ${Math.round((st.ctx || 0) / 1024)}K`),
      st.vision ? h('span', { class: 'badge ok' }, 'Görsel ✓') : h('span', { class: 'badge' }, 'Görsel yok'),
      st.load_seconds ? h('span', { class: 'badge' }, `${st.load_seconds.toFixed(0)} sn'de yüklendi`) : null,
      h('span', { class: 'mono tiny' }, st.base_url || '')));
  }
  for (const w of st.warnings || []) sec.append(h('div', { class: 'row small', style: { color: 'var(--warn)', marginTop: '6px', alignItems: 'flex-start' } }, icon('alert'), h('span', {}, w)));
  if (st.error) sec.append(h('div', { class: 'error-box' }, st.error));
  box.append(sec);
}

async function loadModels() {
  try {
    const r = await S.rpc.call('models.list');
    models = r.models;
    renderLocal(r.dirs);
  } catch (e) { toast(e.message, 'err'); }
}

function renderLocal(dirs) {
  const box = $('m-local');
  if (!box) return;
  box.innerHTML = '';
  const sel = S.settings?.model?.selected;
  const tbl = h('table', { class: 'tbl' }, h('tr', {}, h('th', {}, 'Model'), h('th', {}, 'Boyut'), h('th')));
  for (const m of models) {
    const isSel = sel === m.path;
    const isRunning = S.model?.model_path === m.path && S.model?.state === 'ready';
    tbl.append(h('tr', { class: isSel ? 'sel' : '' },
      h('td', {}, h('div', { class: 'row' }, isRunning ? h('span', { class: 'dot ok' }) : null, h('b', { class: 'nowrap', style: { maxWidth: '360px' }, title: m.path }, m.name)),
        h('div', { class: 'row tiny muted', style: { marginTop: '3px' } }, m.quant ? h('span', { class: 'badge' }, m.quant) : null, m.mmproj ? h('span', { class: 'badge ok', title: m.mmproj }, 'görsel') : null, m.parts > 1 ? h('span', { class: 'badge' }, `${m.parts} parça`) : null)),
      h('td', { class: 'nowrap' }, fmtBytes(m.size_bytes)),
      h('td', { style: { textAlign: 'right', whiteSpace: 'nowrap' } },
        h('button', { class: 'btn sm', title: 'Bellek planını göster', onclick: () => showPlan(m) }, 'Plan'), ' ',
        h('button', { class: 'btn sm primary', onclick: () => start(m.path) }, icon('play'), isRunning ? 'Yeniden' : 'Başlat'), ' ',
        h('button', { class: 'icon-btn', title: 'Sil', onclick: () => del(m) }, icon('trash')))));
  }
  box.append(h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', { class: 'grow' }, `Yerel modeller (${models.length})`), h('button', { class: 'icon-btn', title: 'Yenile', onclick: loadModels }, icon('refresh'))),
    models.length ? tbl : h('div', { class: 'empty' }, 'Henüz model yok. Aşağıdan Hugging Face\'te arayıp indirin ya da GGUF dosyalarını model klasörüne koyun.'),
    h('div', { class: 'tiny muted', style: { marginTop: '8px' } }, 'Klasörler: ', (dirs || []).join(' • '))));
}

async function start(path) {
  try {
    await S.rpc.call('models.start', { model: path });
    toast(`${basename(path)} başlatılıyor…`);
  } catch (e) { toast(e.message, 'err'); }
}

async function del(m) {
  if (!(await confirmBox('Modeli sil', `${m.name} (${fmtBytes(m.size_bytes)}) KALICI olarak silinsin mi?\nBu işlem geri alınamaz.`, 'Kalıcı olarak sil', true))) return;
  try { await S.rpc.call('models.delete', { path: m.path }); loadModels(); toast('Silindi', 'ok'); } catch (e) { toast(e.message, 'err'); }
}

async function showPlan(m) {
  toast('Bellek ölçülüyor…', '', 1500);
  try {
    const r = await S.rpc.call('models.plan', { model: m.path });
    const p = r.plan;
    const i = r.info || {};
    const hw = r.hardware;
    const body = h('div', { class: 'col' },
      p.blocker ? h('div', { class: 'error-box' }, p.blocker) : h('div', {}, h('b', {}, placementLabel(p.placement)), ' — ', p.summary),
      ...(p.warnings || []).map((w) => h('div', { class: 'small', style: { color: 'var(--warn)' } }, w)),
      h('div', { class: 'kv' },
        h('span', { class: 'k' }, 'Mimari'), `${i.architecture || '?'} • ${i.block_count || '?'} katman${i.expert_count > 1 ? ` • MoE ${i.expert_count} uzman` : ''}`,
        h('span', { class: 'k' }, 'Ağırlıklar'), fmtBytes(i.weight_bytes),
        h('span', { class: 'k' }, 'Eğitim bağlamı'), i.context_length ? `${Math.round(i.context_length / 1024)}K` : '?',
        h('span', { class: 'k' }, 'GPU'), hw.gpus?.[0] ? `${hw.gpus[0].name} — ${fmtBytes(hw.gpus[0].free_bytes)} boş / ${fmtBytes(hw.gpus[0].total_bytes)}${hw.unified_memory ? ' (paylaşımlı)' : ''}` : 'yok',
        h('span', { class: 'k' }, 'RAM'), `${fmtBytes(hw.ram_available_bytes)} boş / ${fmtBytes(hw.ram_total_bytes)}`,
        h('span', { class: 'k' }, 'Parametreler'), h('span', { class: 'mono tiny' }, (p.args || []).join(' '))));
    const { modal } = await import('../util.js');
    modal({ title: m.name, body, wide: true, actions: [{ label: 'Kapat' }, p.blocker ? null : { label: 'Başlat', cls: 'primary', run: () => start(m.path) }].filter(Boolean) });
  } catch (e) { toast(e.message, 'err'); }
}

function renderRun() {
  const box = $('m-run');
  if (!box) return;
  const ms = S.settings.model;
  box.innerHTML = '';
  const seg = (key, opts, cur, onPick) => h('div', { class: 'seg' }, opts.map(([v, l]) => h('button', { class: v === cur ? 'on' : '', onclick: () => onPick(v) }, l)));
  const ctxSel = h('select', {}, [[0, 'Otomatik'], [8192, '8K'], [16384, '16K'], [32768, '32K'], [65536, '64K'], [131072, '128K'], [262144, '256K']].map(([v, l]) => h('option', { value: v, selected: Number(ms.context) === v }, l)));
  ctxSel.onchange = () => saveSettings({ model: { context: Number(ctxSel.value) } }).then(renderRun);
  const backend = h('select', {}, [['auto', 'Otomatik'], ['vulkan', 'Vulkan (AMD/Intel/NVIDIA)'], ['cuda', 'CUDA (NVIDIA)'], ['hip', 'ROCm/HIP (AMD)'], ['cpu', 'Yalnızca CPU'], ['metal', 'Metal (Apple)']].map(([v, l]) => h('option', { value: v, selected: ms.backend === v }, l)));
  backend.onchange = () => saveSettings({ model: { backend: backend.value } });
  box.append(h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', {}, 'Çalıştırma')),
    h('div', { class: 'field' }, h('div', { class: 'lbl' }, 'Yerleşim', h('small', {}, 'GPU/RAM kullanımı')),
      seg('mode', [['auto', 'Otomatik'], ['gpu', 'GPU'], ['hybrid', 'CPU offload'], ['cpu', 'CPU']], ms.compute_mode, (v) => saveSettings({ model: { compute_mode: v } }).then(renderRun))),
    h('div', { class: 'tiny muted' }, {
      auto: 'Belleği ölçer: sığıyorsa tamamı GPU\'da, sığmıyorsa GPU + RAM. Bağlamı da buna göre seçer.',
      gpu: 'En hızlısı; model ve bağlam GPU belleğine sığmalı, sığmazsa başlatılmaz.',
      hybrid: 'Büyük MoE modeller için: uzmanlar RAM\'de, dikkat katmanları ve bağlam GPU\'da.',
      cpu: 'Ekran kartı kullanılmaz; en uyumlu ama en yavaş.',
    }[ms.compute_mode]),
    h('div', { class: 'field' }, h('div', { class: 'lbl' }, 'Bağlam boyutu', h('small', {}, 'Ajan için en az 16K önerilir')), ctxSel),
    h('div', { class: 'field' }, h('div', { class: 'lbl' }, 'Açılışta başlat'), h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: ms.auto_start, onchange: (e) => saveSettings({ model: { auto_start: e.target.checked } }) }), 'Seçili modeli FerIDE açılınca yükle')),
    h('div', { class: 'field' }, h('div', { class: 'lbl' }, 'llama.cpp derlemesi', h('small', {}, 'Değiştirince yeniden kurun')), h('div', { class: 'row' }, backend,
      h('button', { class: 'btn sm', onclick: async () => { await S.rpc.call('setup.install', { ids: ['llama'] }); toast('llama.cpp en son sürüme güncelleniyor (Kurulum sayfasından izleyebilirsiniz).'); } }, icon('refresh'), 'Kur / güncelle')))));
}

function renderDownloads() {
  const box = $('m-downloads');
  if (!box) return;
  box.innerHTML = '';
  const list = [...downloads.values()].filter((d) => d.state !== 'done' || Date.now() - (d._seen || (d._seen = Date.now())) < 60000);
  if (!list.length) return;
  const sec = h('div', { class: 'section' }, h('div', { class: 'sh' }, h('h3', {}, 'İndirmeler')));
  for (const d of list) {
    const pct = d.total ? Math.round((d.done / d.total) * 100) : 0;
    const stLabel = { running: `${fmtBytes(d.done)} / ${fmtBytes(d.total)} • ${fmtBytes(d.speed)}/sn`, verifying: 'Doğrulanıyor…', done: 'Tamamlandı', failed: 'Başarısız', cancelled: 'İptal edildi' }[d.state];
    sec.append(h('div', { style: { padding: '6px 0' } },
      h('div', { class: 'row' }, h('b', { class: 'nowrap grow' }, basename(d.file)), h('span', { class: 'small muted' }, stLabel),
        d.state === 'running' ? h('button', { class: 'btn sm', onclick: () => S.rpc.call('hub.cancel', { id: d.id }) }, 'İptal') : null,
        d.state === 'done' ? h('button', { class: 'btn sm primary', onclick: () => start(d.dest) }, icon('play'), 'Çalıştır') : null),
      h('div', { class: 'progress', style: { marginTop: '5px' } }, h('div', { style: { width: `${d.state === 'done' ? 100 : pct}%` } })),
      d.error ? h('div', { class: 'small', style: { color: 'var(--err)', marginTop: '4px' } }, d.error) : null));
  }
  box.append(sec);
}

function renderHub() {
  const box = $('m-hub');
  if (!box) return;
  box.innerHTML = '';
  const q = h('input', { type: 'search', placeholder: 'Hugging Face\'te GGUF ara (ör. qwen3 coder, gemma 3, unsloth)…', value: hubState.query, style: { flex: 1 } });
  const results = h('div');
  const search = async () => {
    hubState.query = q.value.trim();
    if (!hubState.query) return;
    results.innerHTML = '';
    results.append(h('div', { class: 'status-line' }, icon('loader', 'spin'), 'Aranıyor…'));
    try {
      hubState.results = await S.rpc.call('hub.search', { query: hubState.query });
      hubState.repo = null;
      fillResults(results);
    } catch (e) { results.innerHTML = ''; results.append(h('div', { class: 'error-box' }, e.message)); }
  };
  q.addEventListener('keydown', (e) => { if (e.key === 'Enter') search(); });
  box.append(h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', { class: 'grow' }, 'Hugging Face\'ten indir'), h('span', { class: 'tiny muted' }, 'Kapalı (gated) modeller için Ayarlar\'a erişim jetonu girin')),
    h('div', { class: 'row' }, q, h('button', { class: 'btn primary', onclick: search }, icon('search'), 'Ara')),
    results));
  if (hubState.results.length) fillResults(results);
}

function fillResults(box) {
  box.innerHTML = '';
  if (hubState.repo) {
    box.append(h('div', { class: 'row', style: { margin: '10px 0' } },
      h('button', { class: 'btn sm', onclick: () => { hubState.repo = null; fillResults(box); } }, '← Sonuçlar'),
      h('b', {}, hubState.repo),
      h('a', { href: '#', class: 'small', onclick: (e) => { e.preventDefault(); window.ferideOpenUrl(`https://huggingface.co/${hubState.repo}`); } }, 'sayfayı aç')));
    if (hubState.loading) { box.append(h('div', { class: 'status-line' }, icon('loader', 'spin'), 'Dosyalar alınıyor…')); return; }
    const mmprojs = hubState.files.filter((f) => f.is_mmproj);
    const withVision = h('input', { type: 'checkbox', checked: mmprojs.length > 0 });
    if (mmprojs.length) box.append(h('label', { class: 'check small', style: { marginBottom: '8px' } }, withVision, `Görsel adaptörünü (${mmprojs[0].path}) de indir`));
    const tbl = h('table', { class: 'tbl' }, h('tr', {}, h('th', {}, 'Dosya'), h('th', {}, 'Kuantizasyon'), h('th', {}, 'Boyut'), h('th')));
    for (const f of hubState.files.filter((x) => !x.is_mmproj)) {
      tbl.append(h('tr', {},
        h('td', { class: 'mono small' }, f.path, f.parts.length ? h('span', { class: 'badge', style: { marginLeft: '6px' } }, `${f.parts.length} parça`) : null),
        h('td', {}, f.quant ? h('span', { class: 'badge' }, f.quant) : ''),
        h('td', { class: 'nowrap' }, fmtBytes(f.total_size)),
        h('td', { style: { textAlign: 'right' } }, h('button', { class: 'btn sm primary', onclick: () => download(f, withVision.checked ? mmprojs[0] : null) }, icon('download'), 'İndir'))));
    }
    box.append(tbl);
    return;
  }
  if (!hubState.results.length) { box.append(h('div', { class: 'empty' }, 'Sonuç yok.')); return; }
  const tbl = h('table', { class: 'tbl', style: { marginTop: '10px' } }, h('tr', {}, h('th', {}, 'Depo'), h('th', {}, 'İndirme'), h('th', {}, 'Güncellendi'), h('th')));
  for (const r of hubState.results) {
    tbl.append(h('tr', { style: { cursor: 'pointer' }, onclick: () => openRepo(r.id, box) },
      h('td', {}, h('b', {}, r.id), r.gated ? h('span', { class: 'badge warn', style: { marginLeft: '6px' } }, 'izin gerekli') : null),
      h('td', {}, r.downloads.toLocaleString('tr-TR')),
      h('td', { class: 'muted small' }, relTime(r.updated)),
      h('td', { style: { textAlign: 'right' } }, icon('chevR'))));
  }
  box.append(tbl);
}

async function openRepo(repo, box) {
  hubState.repo = repo;
  hubState.loading = true;
  fillResults(box);
  try {
    hubState.files = await S.rpc.call('hub.files', { repo });
  } catch (e) { toast(e.message, 'err'); hubState.files = []; }
  hubState.loading = false;
  fillResults(box);
}

async function download(f, mmproj) {
  try {
    await S.rpc.call('hub.download', { repo: hubState.repo, file: f.path, parts: f.parts });
    if (mmproj) await S.rpc.call('hub.download', { repo: hubState.repo, file: mmproj.path, mmproj_for: basename(f.path) });
    toast('İndirme başladı.', 'ok');
  } catch (e) { toast(e.message, 'err'); }
}

function renderProvider() {
  const box = $('m-provider');
  if (!box) return;
  const p = S.settings.provider;
  box.innerHTML = '';
  const url = h('input', { type: 'text', value: p.base_url, placeholder: 'https://…/v1 ya da http://127.0.0.1:11434/v1', style: { width: '100%' } });
  const model = h('input', { type: 'text', value: p.model, placeholder: 'model adı', style: { width: '100%' } });
  const ctx = h('input', { type: 'number', value: p.context, min: 2048, step: 1024 });
  const key = h('input', { type: 'password', placeholder: S.secretsSet.includes('provider_api_key') ? '•••••• (kayıtlı)' : 'API anahtarı (isteğe bağlı)', style: { width: '100%' } });
  const save = debounce(() => saveSettings({ provider: { base_url: url.value.trim(), model: model.value.trim(), context: Number(ctx.value) || 32768 } }), 500);
  [url, model, ctx].forEach((i) => i.addEventListener('input', save));
  box.append(h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', { class: 'grow' }, 'Model sağlayıcı'),
      h('div', { class: 'seg' },
        h('button', { class: p.kind === 'local' ? 'on' : '', onclick: () => saveSettings({ provider: { kind: 'local' } }).then(renderProvider) }, 'Yerel (llama.cpp)'),
        h('button', { class: p.kind === 'openai' ? 'on' : '', onclick: () => saveSettings({ provider: { kind: 'openai' } }).then(renderProvider) }, 'OpenAI uyumlu uç nokta'))),
    p.kind === 'openai'
      ? h('div', {},
        h('div', { class: 'field' }, h('div', { class: 'lbl' }, 'Adres'), url),
        h('div', { class: 'field' }, h('div', { class: 'lbl' }, 'Model'), model),
        h('div', { class: 'field' }, h('div', { class: 'lbl' }, 'Bağlam (token)'), ctx),
        h('div', { class: 'field' }, h('div', { class: 'lbl' }, 'API anahtarı', h('small', {}, 'Windows\'ta DPAPI ile şifrelenir')), h('div', { class: 'row' }, key,
          h('button', { class: 'btn sm', onclick: async () => { await S.rpc.call('secrets.set', { key: 'provider_api_key', value: key.value }); key.value = ''; await import('../app.js').then((a) => a.loadSettings()); renderProvider(); toast('Kaydedildi', 'ok'); } }, 'Kaydet'))),
        h('div', { class: 'tiny muted' }, 'Ollama, LM Studio, vLLM, başka bir bilgisayardaki llama-server ya da bulut sağlayıcılar. Uzak uç noktada konuşmalarınız o sunucuya gönderilir.'))
      : h('div', { class: 'muted small' }, 'Modeller bu bilgisayarda llama.cpp ile çalışır; hiçbir veri dışarı gönderilmez.')));
}
