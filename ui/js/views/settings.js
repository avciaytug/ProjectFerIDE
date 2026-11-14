// Ayarlar: genel, ajan ve güvenlik, düzenleyici, ses, MCP, skill'ler, hafıza.
import { S, saveSettings, loadSettings, restartForUpdate } from '../app.js';
import { h, icon, toast, relTime, confirmBox, modal, renderMarkdown, fmtBytes } from '../util.js';
import * as Editor from './editor.js';

let tab = 'general';
let el = null;

export function open(which) {
  if (which) tab = which;
  Editor.openPage('page:settings', 'Ayarlar', 'settings', (e) => { el = e; render(); });
}

const TABS = [
  ['general', 'Genel', 'settings'],
  ['agent', 'Ajan ve güvenlik', 'shield'],
  ['mcp', 'MCP sunucuları', 'plug'],
  ['skills', 'Skill\'ler', 'sparkles'],
  ['memory', 'Hafıza', 'brain'],
  ['voice', 'Ses', 'volume'],
];

function render() {
  el.innerHTML = '';
  const nav = h('div', { class: 'row', style: { gap: '4px', flexWrap: 'wrap', margin: '12px 0 4px' } },
    TABS.map(([id, label, ic]) => h('button', { class: `btn ${tab === id ? 'primary' : 'ghost'}`, onclick: () => { tab = id; render(); } }, icon(ic), label)));
  const body = h('div');
  el.append(h('div', { class: 'page-inner' }, h('h2', {}, 'Ayarlar'), nav, body));
  ({ general, agent, mcp, skills, memory, voice })[tab](body);
}

// ---------------------------------------------------------------- güncellemeler
let updateSec = null;

export function onUpdate() {
  if (updateSec?.isConnected) renderUpdate(updateSec);
}

function renderUpdate(sec) {
  updateSec = sec;
  const u = S.update || { state: 'idle' };
  const pct = u.total ? ` %${Math.floor((u.done * 100) / u.total)}` : '';
  const text = {
    idle: 'Henüz denetlenmedi.',
    checking: 'Denetleniyor…',
    downloading: `FerIDE ${u.latest} arka planda indiriliyor…${pct}`,
    installing: `FerIDE ${u.latest} doğrulanıp kuruluyor…`,
    ready: `FerIDE ${u.ready_version} kuruldu; yeniden başlatınca geçerli olur.`,
    up_to_date: `Güncel${u.latest ? ` (GitHub'daki en yeni sürüm ${u.latest})` : ''}.`,
    error: u.message || 'Denetlenemedi.',
    unsupported: u.message || 'Bu kopya kendini güncelleyemiyor.',
  }[u.state] || '';
  const busy = ['checking', 'downloading', 'installing'].includes(u.state);
  sec.innerHTML = '';
  sec.append(
    h('div', { class: 'sh' }, h('h3', {}, 'Güncellemeler')),
    field('Otomatik güncelleme', 'FerIDE açıkken GitHub\'daki yeni sürümleri denetler (açılıştan 1 dakika sonra, sonra 6 saatte bir), yeni sürümü arka planda indirip doğrular ve kurar. Yeni sürüm FerIDE yeniden başlatılınca devreye girer.',
      u.updatable === false ? h('span', { class: 'small muted' }, 'Bu kopyada kullanılamaz') : check(S.settings.updates?.auto !== false, async (v) => { await saveSettings({ updates: { auto: v } }); if (v) S.rpc.call('update.check').catch(() => {}); }, 'Yeni sürümleri otomatik indir ve kur')),
    field('Durum', `Çalışan sürüm: ${u.current || S.info?.version || ''}${u.checked_at ? ` • son denetim ${relTime(u.checked_at)}` : ''}`,
      h('div', { class: 'row', style: { flexWrap: 'wrap', justifyContent: 'flex-end' } },
        h('span', { class: 'small', style: { maxWidth: '440px', color: u.state === 'error' ? 'var(--err)' : u.state === 'ready' ? 'var(--accent)' : '' } }, busy ? icon('loader', 'spin') : null, ' ', text),
        u.state === 'ready' ? h('button', { class: 'btn sm primary', onclick: () => restartForUpdate() }, icon('refresh'), 'Yeniden başlat') : null,
        u.updatable && !busy ? h('button', { class: 'btn sm', onclick: () => S.rpc.call('update.check').catch((e) => toast(e.message, 'err')) }, icon('refresh'), 'Şimdi denetle') : null,
        u.page_url ? h('button', { class: 'btn sm ghost', onclick: () => S.rpc.call('app.open_url', { url: u.page_url }) }, 'Sürüm notları') : null)));
}

function renderInstall(sec, inst) {
  sec.lastChild.remove();
  sec.append(
    field('Program klasörü', inst.installed ? 'FerIDE buraya kurulu' : 'Bu kopya kurulmadan (taşınabilir) çalışıyor', h('div', { class: 'row' },
      h('span', { class: 'mono small nowrap', style: { maxWidth: '420px' }, title: inst.exe_dir }, inst.exe_dir),
      h('button', { class: 'btn sm', onclick: () => S.rpc.call('app.open_path', { path: inst.exe_dir }).catch((e) => toast(e.message, 'err')) }, icon('folder'), 'Aç'))),
    field('Kaldır', inst.installed ? 'Program, kısayollar ve kaldırma kaydı silinir; modelleri silmek isteğe bağlıdır.' : 'Kaldırmak için program klasörünü silmeniz yeterli.',
      inst.installed ? h('button', { class: 'btn sm danger', onclick: () => uninstallDialog(inst) }, icon('trash'), 'FerIDE\'yi kaldır…') : h('span', { class: 'small muted' }, '—')));
}

async function uninstallDialog(inst) {
  const purge = h('input', { type: 'checkbox' });
  const sizeEl = h('span', { class: 'muted' }, 'hesaplanıyor…');
  S.rpc.call('app.data_size').then((n) => { sizeEl.textContent = fmtBytes(n); }).catch(() => { sizeEl.textContent = '?'; });
  modal({
    title: 'FerIDE kaldırılsın mı?',
    body: h('div', { class: 'col' },
      h('div', {}, 'FerIDE kapatılacak; program dosyaları, kısayollar ve "Uygulamalar" kaydı silinecek.'),
      h('label', { class: 'check', style: { alignItems: 'flex-start' } }, purge,
        h('span', {}, 'Modelleri, sohbetleri, indirilen araçları ve ayarları da sil (', sizeEl, ')',
          h('div', { class: 'mono tiny muted' }, inst.data_dir))),
      h('div', { class: 'tiny muted' }, 'İşaretlemezseniz veri klasörü yerinde kalır; FerIDE\'yi yeniden kurduğunuzda kaldığınız yerden devam eder.')),
    actions: [
      { label: 'Vazgeç' },
      {
        label: 'Kaldır',
        cls: 'danger',
        run: () => {
          (async () => {
            if (purge.checked && !(await confirmBox('Veriler kalıcı olarak silinsin mi?', `${inst.data_dir}\n\nİndirdiğiniz modeller, sohbetler ve ayarlar kalıcı olarak silinecek. Bu işlem geri alınamaz.`, 'Kalıcı olarak sil', true))) return;
            try {
              await S.rpc.call('app.uninstall', { purge: purge.checked });
              toast('FerIDE kapatılıp kaldırılıyor…', 'warn', 10000);
            } catch (e) { toast(e.message, 'err', 8000); }
          })();
        },
      },
    ],
  });
}

const field = (label, help, control) => h('div', { class: 'field' }, h('div', { class: 'lbl' }, label, help ? h('small', {}, help) : null), control);
const check = (checked, onChange, text) => h('label', { class: 'check' }, h('input', { type: 'checkbox', checked, onchange: (e) => onChange(e.target.checked) }), text || '');
const select = (value, opts, onChange) => {
  const s = h('select', {}, opts.map(([v, l]) => h('option', { value: v, selected: String(v) === String(value) }, l)));
  s.onchange = () => onChange(s.value);
  return s;
};

function general(body) {
  const s = S.settings;
  const hf = h('input', { type: 'password', placeholder: S.secretsSet.includes('hf_token') ? '•••••• (kayıtlı)' : 'hf_…', style: { width: '260px' } });
  body.append(h('div', { class: 'section' },
    field('Tema', null, select(s.theme, [['dark', 'Koyu'], ['light', 'Açık']], (v) => saveSettings({ theme: v }))),
    field('Yazı boyutu (düzenleyici)', null, select(s.editor.font_size, [12, 13, 14, 15, 16, 18].map((n) => [n, `${n} px`]), (v) => saveSettings({ editor: { font_size: Number(v) } }))),
    field('Sekme genişliği', null, select(s.editor.tab_size, [[2, '2'], [4, '4'], [8, '8']], (v) => saveSettings({ editor: { tab_size: Number(v) } }))),
    field('Satır kaydırma', null, check(s.editor.word_wrap, (v) => saveSettings({ editor: { word_wrap: v } }), 'Uzun satırları kaydır')),
    field('Hugging Face jetonu', 'Kapalı (gated) modelleri indirmek için. Şifreli saklanır.', h('div', { class: 'row' }, hf,
      h('button', { class: 'btn sm', onclick: async () => { await S.rpc.call('secrets.set', { key: 'hf_token', value: hf.value }); hf.value = ''; await loadSettings(); render(); toast('Kaydedildi', 'ok'); } }, 'Kaydet'),
      S.secretsSet.includes('hf_token') ? h('button', { class: 'btn sm danger', onclick: async () => { await S.rpc.call('secrets.set', { key: 'hf_token', value: '' }); await loadSettings(); render(); } }, 'Sil') : null)),
    field('Veri klasörü', S.info?.data_dir, h('div', { class: 'row' },
      h('button', { class: 'btn sm', onclick: () => S.rpc.call('app.open_path', { path: 'data' }) }, icon('folder'), 'Aç'),
      h('button', { class: 'btn sm', onclick: () => S.rpc.call('app.open_path', { path: 'logs' }) }, icon('file'), 'Günlükler')))));
  const upSec = h('div', { class: 'section' });
  body.append(upSec);
  renderUpdate(upSec);
  const installSec = h('div', { class: 'section' }, h('div', { class: 'sh' }, h('h3', {}, 'Kurulum')), h('div', { class: 'status-line' }, icon('loader', 'spin'), 'Okunuyor…'));
  body.append(installSec);
  S.rpc.call('app.install_info').then((inst) => renderInstall(installSec, inst)).catch((e) => { installSec.lastChild.textContent = e.message; });
  body.append(h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', {}, 'FerIDE hakkında')),
    h('div', { class: 'kv' },
      h('span', { class: 'k' }, 'Sürüm'), `${S.info?.display_version} (${S.info?.version})`,
      h('span', { class: 'k' }, 'Platform'), `${S.info?.os} ${S.info?.arch}`,
      h('span', { class: 'k' }, 'Ajan kabuğu'), S.info?.shell,
      h('span', { class: 'k' }, 'Mimari'), 'Rust çekirdek + yerel sunucu + WebView arayüz')));
}

function agent(body) {
  const a = S.settings.agent;
  const modes = [
    ['plan', 'Plan', 'Salt okunur: inceler, araştırır, plan sunar; hiçbir şeyi değiştirmez.'],
    ['ask', 'Her işlemde sor', 'Okuma dışındaki her işlem için onay ister.'],
    ['auto_edit', 'Düzenlemelere izin ver', 'Çalışma alanındaki dosya değişikliklerine izin verir; komutları sorar. (Önerilen)'],
    ['full_auto', 'Tam otonom', 'Hiçbir şey sorulmaz. Yıkıcı komutlar, FerIDE ayarları, kimlik bilgisi klasörleri ve yerel ağ istekleri yine korunur.'],
  ];
  body.append(h('div', { class: 'section' },
    h('div', { class: 'sh' }, icon('shield'), h('h3', {}, 'İzin modu')),
    h('div', { class: 'col' }, modes.map(([v, l, d]) => h('label', { class: 'check', style: { alignItems: 'flex-start', padding: '6px 0' } },
      h('input', { type: 'radio', name: 'pm', checked: a.permission_mode === v, onchange: () => saveSettings({ agent: { permission_mode: v } }) }),
      h('div', {}, h('b', {}, l), h('div', { class: 'muted small' }, d))))),
    h('div', { class: 'tiny muted', style: { marginTop: '8px' } }, 'Her modda geçerli korumalar: disk biçimlendirme, sistem klasörünü silme, gölge kopyaları silme gibi komutlar engellenir; ajan FerIDE\'nin kendi ayar ve sır dosyalarını değiştiremez; .ssh/.aws gibi klasörlere yazma, başlangıç klasörleri ve yerel ağ adresleri her zaman onaya tabidir; ajanın değiştirdiği her dosyanın önceki hali saklanır ve sohbetten geri alınabilir.')));
  body.append(h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', {}, 'Davranış')),
    field('Kabuk', 'Ajanın ve terminalin kullandığı kabuk', select(a.shell, [['auto', 'Otomatik (Windows\'ta Git Bash)'], ['bash', 'bash'], ['powershell', 'PowerShell'], ['cmd', 'cmd.exe'], ['zsh', 'zsh'], ['sh', 'sh']], (v) => saveSettings({ agent: { shell: v } }))),
    field('En fazla adım', 'Bir görevde en fazla araç turu', select(a.max_steps, [[30, '30'], [60, '60'], [100, '100'], [200, '200'], [400, '400']], (v) => saveSettings({ agent: { max_steps: Number(v) } }))),
    field('Sıcaklık', 'Düşük: tutarlı, yüksek: yaratıcı', select(a.temperature, [[0.2, '0,2'], [0.4, '0,4'], [0.6, '0,6'], [0.8, '0,8'], [1.0, '1,0']], (v) => saveSettings({ agent: { temperature: Number(v) } }))),
    field('Düşünme modu', 'Destekleyen modellerde (Qwen3, GLM…) önce düşünür', check(a.thinking, (v) => saveSettings({ agent: { thinking: v } }), 'Etkin')),
    field('Komut zaman aşımı', null, select(a.command_timeout_secs, [[60, '1 dk'], [300, '5 dk'], [900, '15 dk'], [1800, '30 dk']], (v) => saveSettings({ agent: { command_timeout_secs: Number(v) } }))),
    field('Araç çıktısı sınırı', 'Modele verilen en fazla karakter', select(a.max_tool_output_chars, [[8000, '8 bin'], [16000, '16 bin'], [32000, '32 bin'], [64000, '64 bin']], (v) => saveSettings({ agent: { max_tool_output_chars: Number(v) } })))));
  body.append(h('div', { class: 'section' }, h('div', { class: 'sh' }, h('h3', {}, 'Proje talimatları')),
    h('div', { class: 'small muted' }, 'Çalışma alanının kökündeki FERIDE.md (ya da AGENTS.md / CLAUDE.md) dosyası her görevde ajana proje talimatı olarak verilir. Kod stili, test komutu, yasaklar gibi kalıcı kuralları buraya yazın.')));
}

async function mcp(body) {
  let data;
  try { data = await S.rpc.call('mcp.list'); } catch (e) { body.append(h('div', { class: 'error-box' }, e.message)); return; }
  const sec = h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', { class: 'grow' }, 'MCP sunucuları'),
      h('button', { class: 'btn sm', onclick: editConfig }, icon('edit'), 'Yapılandırmayı düzenle'),
      h('button', { class: 'icon-btn', title: 'Yenile', onclick: () => render() }, icon('refresh'))));
  const tbl = h('table', { class: 'tbl' }, h('tr', {}, h('th', {}, 'Sunucu'), h('th', {}, 'Durum'), h('th', {}, 'Araç'), h('th')));
  for (const s of data.servers) {
    const badge = { ready: 'ok', starting: 'warn', error: 'err' }[s.state] || '';
    const label = { ready: 'Hazır', starting: 'Başlıyor', error: 'Hata', stopped: 'Durdu', disabled: 'Kapalı' }[s.state] || s.state;
    tbl.append(h('tr', {},
      h('td', {}, h('b', {}, s.name), h('div', { class: 'tiny muted' }, s.description), h('div', { class: 'mono tiny muted nowrap', style: { maxWidth: '520px' } }, s.command)),
      h('td', {}, h('span', { class: `badge ${badge}` }, label),
        s.missing_runtime && s.state !== 'disabled' ? h('div', { class: 'tiny', style: { color: 'var(--warn)', marginTop: '4px' } }, s.missing_runtime) : null,
        s.error ? h('div', { class: 'tiny', style: { color: 'var(--err)', marginTop: '4px', whiteSpace: 'pre-wrap' } }, s.error.slice(0, 400)) : null),
      h('td', {}, s.tools || ''),
      h('td', { style: { textAlign: 'right', whiteSpace: 'nowrap' } },
        check(s.state !== 'disabled', async (v) => { await S.rpc.call('mcp.toggle', { name: s.name, enabled: v }).catch((e) => toast(e.message, 'err')); render(); }, 'Etkin'), ' ',
        s.state !== 'disabled' ? h('button', { class: 'btn sm', onclick: async () => { try { await S.rpc.call('mcp.restart', { name: s.name }); } catch (e) { toast(e.message, 'err'); } render(); } }, 'Yeniden başlat') : null)));
  }
  sec.append(tbl);
  body.append(sec);
  if (data.tools.length) {
    body.append(h('div', { class: 'section' }, h('div', { class: 'sh' }, h('h3', {}, `Ajanın kullanabildiği MCP araçları (${data.tools.length})`)),
      h('div', { class: 'col', style: { gap: '4px' } }, data.tools.map((t) => h('div', { class: 'small' }, h('span', { class: 'mono' }, t.full_name), t.read_only ? h('span', { class: 'badge ok', style: { marginLeft: '6px' } }, 'salt okunur') : null, h('span', { class: 'muted' }, ` — ${t.description.slice(0, 160)}`))))));
  }
  body.append(h('div', { class: 'tiny muted', style: { marginTop: '8px' } }, 'MCP araçları "salt okunur" işaretli değilse komut gibi değerlendirilir ve izin moduna göre onay ister. Çıktıları ajana güvenilmeyen veri olarak verilir.'));
}

async function editConfig() {
  const cfg = await S.rpc.call('mcp.config_get');
  const ta = h('textarea', { style: { width: '100%', height: '380px', fontFamily: 'var(--mono)', fontSize: '12px' } }, JSON.stringify(cfg, null, 2));
  modal({
    title: 'mcp_config.json',
    wide: true,
    body: h('div', { class: 'col' }, h('div', { class: 'tiny muted' }, '"command": "npx" | "uvx" | "feride-python" | program yolu. ${FERIDE_HOME} ve ${FERIDE_RESOURCES} kullanılabilir.'), ta),
    actions: [{ label: 'Vazgeç' }, { label: 'Kaydet ve yeniden başlat', cls: 'primary', run: () => {
      let parsed;
      try { parsed = JSON.parse(ta.value); } catch (e) { toast(`Geçersiz JSON: ${e.message}`, 'err'); return false; }
      S.rpc.call('mcp.config_set', { config: parsed }).then(() => { toast('Kaydedildi', 'ok'); render(); }).catch((e) => toast(e.message, 'err'));
      return true;
    } }],
  });
}

async function skills(body) {
  const list = await S.rpc.call('skills.list');
  const sec = h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', { class: 'grow' }, `Skill'ler (${list.length})`), h('button', { class: 'btn sm', onclick: () => S.rpc.call('app.open_path', { path: 'skills' }) }, icon('folder'), 'Klasörü aç')),
    h('div', { class: 'tiny muted', style: { marginBottom: '8px' } }, 'Skill\'ler SKILL.md dosyalarıdır (Anthropic Agent Skills biçimi). Ajan göreve uyanı kendisi seçip yükler. Projeye özel skill\'ler için çalışma alanında .feride/skills/ klasörünü kullanın.'));
  for (const s of list) {
    sec.append(h('div', { class: 'dep' },
      h('div', { class: 'ic' }, icon('sparkles')),
      h('div', { class: 'grow' }, h('div', { class: 'row' }, h('b', {}, s.name), h('span', { class: 'badge' }, s.source)), h('div', { class: 'small muted' }, s.description)),
      h('button', { class: 'btn sm ghost', onclick: async () => { const t = await S.rpc.call('skills.read', { name: s.name }); modal({ title: s.name, wide: true, body: renderMarkdown(t.replace(/^---[\s\S]*?---/, '')), actions: [{ label: 'Kapat' }] }); } }, 'Göster'),
      check(s.enabled, async (v) => { await S.rpc.call('skills.toggle', { name: s.name, enabled: v }); }, 'Etkin')));
  }
  body.append(sec);
}

async function memory(body) {
  const list = await S.rpc.call('memory.list');
  const input = h('input', { type: 'text', placeholder: 'Feride\'nin hatırlamasını istediğiniz bir bilgi (ör. "Yanıtlarını kısa tut")', style: { flex: 1 } });
  const kind = select('preference', [['preference', 'Tercih'], ['fact', 'Bilgi'], ['project', 'Proje']], () => {});
  const sec = h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', {}, `Hafıza (${list.length})`)),
    h('div', { class: 'tiny muted', style: { marginBottom: '8px' } }, 'Tercihler her görevde ajana verilir; diğer kayıtlar konuyla ilgiliyse hatırlanır. Ajan da "remember" aracıyla kayıt ekleyebilir.'),
    h('div', { class: 'row' }, input, kind, h('button', { class: 'btn primary', onclick: async () => { if (!input.value.trim()) return; await S.rpc.call('memory.add', { content: input.value, kind: kind.value }); render(); } }, icon('plus'), 'Ekle')));
  const tbl = h('table', { class: 'tbl', style: { marginTop: '10px' } });
  for (const m of list) {
    tbl.append(h('tr', {},
      h('td', { style: { width: '90px' } }, h('span', { class: 'badge' }, { preference: 'tercih', fact: 'bilgi', project: 'proje', experience: 'deneyim' }[m.kind] || m.kind)),
      h('td', { style: { whiteSpace: 'pre-wrap' } }, m.content),
      h('td', { class: 'tiny muted nowrap' }, relTime(m.created_at)),
      h('td', {}, h('button', { class: 'icon-btn', title: 'Sil', onclick: async () => { if (await confirmBox('Sil', 'Bu hafıza kaydı silinsin mi?', 'Sil', true)) { await S.rpc.call('memory.delete', { id: m.id }); render(); } } }, icon('trash')))));
  }
  sec.append(list.length ? tbl : h('div', { class: 'empty' }, 'Henüz kayıt yok.'));
  body.append(sec);
}

async function voice(body) {
  const v = S.settings.voice;
  const st = await S.rpc.call('voice.status').catch(() => ({ installed: false }));
  body.append(h('div', { class: 'section' },
    h('div', { class: 'sh' }, h('h3', { class: 'grow' }, 'Ses'),
      !st.installed ? h('span', { class: 'badge warn' }, 'Ses paketi kurulu değil') : st.update_needed ? h('span', { class: 'badge warn' }, 'Güncelleme var') : h('span', { class: 'badge ok' }, 'Ses paketi kurulu')),
    !st.installed || st.update_needed ? h('div', { class: 'row', style: { marginBottom: '8px' } },
      h('span', { class: 'small muted grow' }, st.update_needed
        ? 'Ses paketinin yeni sürümü: Feride\'nin kadın sesi (Ahenk Cep) ve ekran kartında çalışan, Türkçede çok daha doğru konuşma tanıma (Whisper large-v3-turbo). Kurulu parçalar yeniden indirilmez.'
        : 'Konuşmayı yazıya çevirme (Whisper), Türkçe sesli yanıt ve canlı sesli sohbet için ses paketini kurun (~4,4 GB, tamamen yerel).'),
      h('button', { class: 'btn primary sm', onclick: async () => { await S.rpc.call('setup.install', { ids: ['voice'] }); toast('Ses paketi kuruluyor; ilerlemeyi Kurulum sayfasında görebilirsiniz.'); import('./setup.js').then((m) => m.open()); } }, icon('download'), st.update_needed ? 'Güncelle' : 'Kur')) : null,
    field('Ses', null, select(v.voice, [['female', 'Feride — Ahenk Cep (kadın)'], ['male', 'Erkek ses — Piper (DFKI)']], (x) => saveSettings({ voice: { voice: x } }))),
    field('Konuşma tanıma', 'Canlı sohbette', select(v.stt_quality === 'fast' ? 'fast' : 'auto', [['auto', 'En doğru — Whisper large-v3-turbo (önerilen)'], ['fast', 'Hızlı — Whisper small (~1 sn, Türkçede daha çok hata)']], (x) => saveSettings({ voice: { stt_quality: x } }))),
    field('Konuşma hızı', null, select(v.speed, [[0.8, 'Yavaş'], [1.0, 'Normal'], [1.15, 'Hızlı'], [1.3, 'Çok hızlı']], (x) => saveSettings({ voice: { speed: Number(x) } }))),
    field('Yanıtları sesli oku', 'Ajan her görev sonunda yanıtını okur', check(v.auto_speak, (x) => saveSettings({ voice: { auto_speak: x } }), 'Etkin')),
    field('Dene', null, h('button', { class: 'btn sm', disabled: !st.installed, onclick: () => import('./chat.js').then((c) => c.speak('Merhaba, ben Feride. Sesim düzgün geliyor mu?')) }, icon('volume'), 'Örnek cümle'))));
}
