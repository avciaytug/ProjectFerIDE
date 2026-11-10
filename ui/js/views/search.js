// Çalışma alanında arama.
import { S } from '../app.js';
import { h, icon, basename, debounce } from '../util.js';
import * as Editor from './editor.js';

let state = { query: '', regex: false, caseSens: false, include: '' };

export function render(panel) {
  panel.innerHTML = '';
  const input = h('input', { type: 'search', placeholder: 'Ara…', value: state.query, style: { width: '100%' } });
  const inc = h('input', { type: 'text', placeholder: 'Dosya deseni (ör. *.rs)', value: state.include, style: { width: '100%' } });
  const results = h('div', { class: 'panel-body' });
  const run = debounce(async () => {
    state.query = input.value;
    state.include = inc.value;
    results.innerHTML = '';
    if (state.query.trim().length < 2) return;
    results.append(h('div', { class: 'status-line', style: { padding: '8px 12px' } }, icon('loader', 'spin'), 'Aranıyor…'));
    try {
      const hits = await S.rpc.call('fs.search', { query: state.query, regex: state.regex, case: state.caseSens, include: state.include });
      results.innerHTML = '';
      if (!hits.length) { results.append(h('div', { class: 'empty' }, 'Sonuç yok.')); return; }
      const byFile = new Map();
      for (const hit of hits) {
        if (!byFile.has(hit.path)) byFile.set(hit.path, []);
        byFile.get(hit.path).push(hit);
      }
      results.append(h('div', { class: 'muted small', style: { padding: '6px 12px' } }, `${hits.length} sonuç, ${byFile.size} dosya`));
      for (const [path, list] of byFile) {
        results.append(h('div', { class: 'tree-row', style: { paddingLeft: '10px', fontWeight: 600 }, title: path }, icon('file'), h('span', { class: 'name' }, basename(path)), h('span', { class: 'muted tiny' }, list.length)));
        for (const hit of list) {
          results.append(h('div', { class: 'tree-row', style: { paddingLeft: '28px' }, onclick: () => Editor.openFile(path, hit.line) },
            h('span', { class: 'muted tiny', style: { minWidth: '30px' } }, hit.line), h('span', { class: 'name mono small' }, hit.text)));
        }
      }
    } catch (e) {
      results.innerHTML = '';
      results.append(h('div', { class: 'empty' }, e.message));
    }
  }, 350);
  input.addEventListener('input', run);
  inc.addEventListener('input', run);
  const tog = (key, label, title) => h('button', {
    class: `btn sm ${state[key] ? 'primary' : ''}`, title,
    onclick: (e) => { state[key] = !state[key]; e.currentTarget.classList.toggle('primary'); run(); },
  }, label);
  panel.append(
    h('div', { class: 'panel-head' }, 'Ara'),
    h('div', { class: 'col', style: { padding: '10px 10px 6px' } }, input, h('div', { class: 'row' }, inc, tog('regex', '.*', 'Düzenli ifade'), tog('caseSens', 'Aa', 'Büyük/küçük harf duyarlı'))),
    results);
  setTimeout(() => input.focus(), 0);
  if (state.query) run();
}
