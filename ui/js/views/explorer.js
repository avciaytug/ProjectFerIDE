// Dosya gezgini.
import { S, refreshInfo, refreshGit } from '../app.js';
import { h, icon, toast, basename, dirname, joinPath, contextMenu, promptBox, confirmBox } from '../util.js';
import * as Editor from './editor.js';
import * as Chat from './chat.js';

const expanded = new Set();
let selected = null;
let root = null;
let showHidden = false;

export async function pickWorkspace() {
  const p = await S.rpc.call('fs.pick_folder');
  let path = p;
  if (!path && !S.info?.desktop) path = await promptBox('Çalışma klasörü', 'Klasörün tam yolunu yazın:', S.info?.workspace || '');
  if (!path) return;
  try {
    await S.rpc.call('fs.open_workspace', { path });
    expanded.clear();
    await refreshInfo();
    refreshGit();
    if (root) render(root);
    toast(`Çalışma klasörü: ${basename(path)}`, 'ok');
  } catch (e) {
    toast(e.message, 'err');
  }
}

export function render(panel) {
  root = panel;
  panel.innerHTML = '';
  const ws = S.info?.workspace;
  const tree = h('div', { class: 'tree' });
  panel.append(
    h('div', { class: 'panel-head' },
      h('span', { class: 'nowrap grow', title: ws }, basename(ws) || 'Gezgin'),
      h('button', { class: 'icon-btn', title: 'Yeni dosya', onclick: () => createIn(ws, false) }, icon('plus')),
      h('button', { class: 'icon-btn', title: 'Gizli dosyaları göster/gizle', onclick: () => { showHidden = !showHidden; render(panel); } }, icon('layers')),
      h('button', { class: 'icon-btn', title: 'Yenile', onclick: () => render(panel) }, icon('refresh')),
      h('button', { class: 'icon-btn', title: 'Klasör aç', onclick: pickWorkspace }, icon('folderOpen'))),
    h('div', { class: 'panel-body' }, tree));
  if (!ws) {
    tree.append(h('div', { class: 'empty' }, 'Henüz klasör açılmadı.', h('br'), h('button', { class: 'btn primary', onclick: pickWorkspace }, icon('folderOpen'), 'Klasör aç')));
    return;
  }
  expanded.add(ws);
  loadDir(tree, ws, 0);
}

function gitMark(path) {
  if (!S.git?.changes || !S.info?.workspace) return null;
  const rel = path.slice(S.info.workspace.length + 1).replace(/\\/g, '/');
  const c = S.git.changes.find(([, p]) => p === rel || p.startsWith(`${rel}/`));
  return c ? c[0] : null;
}

async function loadDir(container, dir, depth) {
  let entries;
  try {
    entries = await S.rpc.call('fs.list', { path: dir });
  } catch (e) {
    container.append(h('div', { class: 'muted small', style: { paddingLeft: `${depth * 12 + 24}px` } }, e.message));
    return;
  }
  for (const e of entries) {
    if (!showHidden && e.hidden && e.name !== '.github') continue;
    const row = h('div', {
      class: `tree-row ${selected === e.path ? 'selected' : ''} ${e.hidden ? 'dim' : ''}`,
      style: { paddingLeft: `${depth * 12 + 6}px` },
      title: e.path,
    });
    const children = h('div');
    const tw = h('span', { class: 'tw' }, e.is_dir ? icon(expanded.has(e.path) ? 'chevD' : 'chevR') : '');
    const g = gitMark(e.path);
    row.append(tw, icon(e.is_dir ? (expanded.has(e.path) ? 'folderOpen' : 'folder') : 'file'), h('span', { class: 'name' }, e.name));
    if (g) row.append(h('span', { class: `git git-${g}` }, g));
    row.addEventListener('click', async () => {
      selected = e.path;
      root.querySelectorAll('.tree-row.selected').forEach((r) => r.classList.remove('selected'));
      row.classList.add('selected');
      if (e.is_dir) {
        if (expanded.has(e.path)) { expanded.delete(e.path); children.innerHTML = ''; }
        else { expanded.add(e.path); await loadDir(children, e.path, depth + 1); }
        tw.innerHTML = '';
        tw.append(icon(expanded.has(e.path) ? 'chevD' : 'chevR'));
      } else {
        Editor.openFile(e.path);
      }
    });
    row.addEventListener('contextmenu', (ev) => {
      ev.preventDefault();
      const items = [];
      if (e.is_dir) {
        items.push({ label: 'Yeni dosya', icon: 'plus', run: () => createIn(e.path, false) });
        items.push({ label: 'Yeni klasör', icon: 'folder', run: () => createIn(e.path, true) });
        items.push({ label: 'Burada terminal aç', icon: 'terminal', run: () => import('./bottom.js').then((b) => b.openTerminal(e.path)) });
      }
      items.push({ label: 'Ajana ekle (@ bahset)', icon: 'chat', run: () => Chat.mention(e.path) });
      items.push({ label: 'Yeniden adlandır', icon: 'edit', run: () => renameEntry(e) });
      items.push({ label: 'Sistemde aç', icon: 'external', run: () => S.rpc.call('app.open_path', { path: e.path }) });
      items.push('-');
      items.push({ label: 'Sil (FerIDE çöp kutusuna)', icon: 'trash', run: () => deleteEntry(e) });
      contextMenu(ev.clientX, ev.clientY, items);
    });
    container.append(row, children);
    if (e.is_dir && expanded.has(e.path)) loadDir(children, e.path, depth + 1);
  }
}

async function createIn(dir, isDir) {
  const name = await promptBox(isDir ? 'Yeni klasör' : 'Yeni dosya', 'Ad:');
  if (!name) return;
  const path = joinPath(dir, name);
  try {
    await S.rpc.call('fs.create', { path, dir: isDir });
    expanded.add(dir);
    render(root);
    if (!isDir) Editor.openFile(path);
  } catch (e) { toast(e.message, 'err'); }
}

async function renameEntry(e) {
  const name = await promptBox('Yeniden adlandır', 'Yeni ad:', e.name);
  if (!name || name === e.name) return;
  try {
    await S.rpc.call('fs.rename', { from: e.path, to: joinPath(dirname(e.path), name) });
    render(root);
  } catch (err) { toast(err.message, 'err'); }
}

async function deleteEntry(e) {
  if (!(await confirmBox('Sil', `"${e.name}" FerIDE çöp kutusuna taşınsın mı?\n(~/.feride/trash altından geri alınabilir)`, 'Sil', true))) return;
  try {
    await S.rpc.call('fs.delete', { path: e.path });
    Editor.closePath(e.path);
    render(root);
  } catch (err) { toast(err.message, 'err'); }
}
