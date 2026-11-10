// Sohbet listesi.
import { S } from '../app.js';
import { h, icon, relTime, toast, promptBox, confirmBox, contextMenu } from '../util.js';
import * as Chat from './chat.js';

let panelEl = null;
let filter = '';

export async function render(panel) {
  panelEl = panel;
  panel.innerHTML = '';
  const list = h('div', { class: 'panel-body' });
  const f = h('input', { type: 'search', placeholder: 'Sohbetlerde ara…', value: filter, style: { width: '100%' } });
  f.addEventListener('input', () => { filter = f.value; fill(list); });
  panel.append(
    h('div', { class: 'panel-head' }, h('span', { class: 'grow' }, 'Sohbetler'), h('button', { class: 'icon-btn', title: 'Yeni sohbet', onclick: () => Chat.newChat() }, icon('plus'))),
    h('div', { style: { padding: '8px 10px' } }, f),
    list);
  fill(list);
}

async function fill(list) {
  let data;
  try { data = await S.rpc.call('chat.sessions'); } catch (e) { list.innerHTML = ''; list.append(h('div', { class: 'empty' }, e.message)); return; }
  list.innerHTML = '';
  const items = data.sessions.filter((s) => !filter || s.title.toLowerCase().includes(filter.toLowerCase()));
  if (!items.length) { list.append(h('div', { class: 'empty' }, 'Henüz sohbet yok.')); return; }
  for (const s of items) {
    const running = data.running.includes(s.id);
    const row = h('div', { class: `list-item ${Chat.currentId() === s.id ? 'active' : ''}`, onclick: () => Chat.load(s.id) },
      running ? h('span', { class: 'dot warn', title: 'Çalışıyor' }) : s.pinned ? icon('pin') : icon('chat'),
      h('div', { class: 'grow' }, h('div', { class: 't' }, s.title), h('div', { class: 'muted tiny' }, relTime(s.updated_at), s.workspace ? ` • ${String(s.workspace).split(/[\\/]/).pop()}` : '')),
      h('div', { class: 'acts' }, h('button', { class: 'icon-btn', title: 'Diğer', onclick: (e) => { e.stopPropagation(); menu(e, s); } }, icon('more'))));
    row.addEventListener('contextmenu', (e) => { e.preventDefault(); menu(e, s); });
    list.append(row);
  }
}

function menu(e, s) {
  contextMenu(e.clientX, e.clientY, [
    { label: 'Yeniden adlandır', icon: 'edit', run: async () => { const t = await promptBox('Yeniden adlandır', 'Başlık:', s.title); if (t) { await S.rpc.call('chat.rename', { id: s.id, title: t }); refresh(); } } },
    { label: s.pinned ? 'Sabitlemeyi kaldır' : 'Sabitle', icon: 'pin', run: async () => { await S.rpc.call('chat.pin', { id: s.id, pinned: !s.pinned }); refresh(); } },
    { label: 'Markdown olarak kopyala', icon: 'copy', run: async () => { const md = await S.rpc.call('chat.export', { id: s.id }); navigator.clipboard?.writeText(md); toast('Kopyalandı', 'ok'); } },
    '-',
    { label: 'Sil', icon: 'trash', run: async () => {
      if (!(await confirmBox('Sohbeti sil', `"${s.title}" silinsin mi?`, 'Sil', true))) return;
      await S.rpc.call('chat.delete', { id: s.id });
      if (Chat.currentId() === s.id) Chat.newChat();
      refresh();
    } },
  ]);
}

export function refresh() {
  if (panelEl && panelEl.isConnected && panelEl.querySelector('.panel-body')) render(panelEl);
}

export function onAgentEvent(ev) {
  if (ev.kind === 'start' || ev.kind === 'done') refresh();
}
