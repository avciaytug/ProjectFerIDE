// FerIDE tarayıcı betiği. Sayfanın yalıtılmış bir dünyasında (isolated world) çalışır: sayfanın kendi betikleri
// buradaki değişkenleri göremez, DOM ise ortaktır. Görevleri:
//  - snapshot: sayfanın kısa metin görüntüsü; tıklanabilir/yazılabilir öğeler [numara] ile işaretlenir
//  - info / point / prepType / select / scroll / setValue: numaralı öğeler üzerinde işlem hazırlığı
// Numaralar öğeye bağlıdır (WeakMap): aynı belgede aynı öğe hep aynı numarayı alır. Yeni belgede numaralar sıfırlanır.
(() => {
  if (globalThis.__fr) return;
  const refs = new Map();
  const ids = new WeakMap();
  let next = 1;
  const LIMIT = 150000;
  const SKIP = new Set(['script', 'style', 'noscript', 'template', 'svg', 'canvas', 'head', 'meta', 'link', 'title', 'object', 'embed',
    'audio', 'video', 'source', 'track', 'map', 'datalist', 'option', 'optgroup', 'picture', 'img']);
  const TEXT_TYPES = new Set(['text', 'search', 'email', 'tel', 'url', 'password', 'number', '']);
  const DATE_TYPES = new Set(['date', 'datetime-local', 'month', 'week', 'time']);
  const BLOCKY = /^(block|flex|grid|list-item|table|table-row|table-caption|flow-root|table-row-group|table-header-group|table-footer-group)$/;
  const ACTION_ROLES = new Set(['button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
    'option', 'combobox', 'textbox', 'searchbox', 'slider', 'spinbutton', 'treeitem', 'select', 'file', 'color', ...DATE_TYPES]);
  const ACTION_SEL = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[contenteditable]:not([contenteditable=false]),[onclick],' +
    '[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],[role=tab],[role=menuitem],[role=menuitemcheckbox],' +
    '[role=menuitemradio],[role=option],[role=combobox],[role=textbox],[role=searchbox],[role=slider],[role=spinbutton],[role=treeitem]';

  const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const cut = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
  const q = (s) => s.replace(/"/g, "'");
  const fold = (s) => (s || '').toLocaleLowerCase('tr').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/ı/g, 'i');
  const cssOf = (el) => (el.ownerDocument.defaultView || window).getComputedStyle(el);

  function refOf(el) {
    let id = ids.get(el);
    if (!id) { id = next++; ids.set(el, id); }
    refs.set(id, new WeakRef(el));
    return id;
  }
  function byRef(n) {
    const w = refs.get(Number(n));
    const el = w && w.deref();
    return el && el.isConnected ? el : null;
  }
  // Gölge DOM ve aynı kökenli çerçeveler dahil, odaktaki en içteki öğe.
  function deepActive() {
    let a = document.activeElement;
    for (let i = 0; i < 20 && a; i++) {
      if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
      if (a.localName === 'iframe' || a.localName === 'frame') {
        try {
          const d = a.contentDocument;
          if (d && d.activeElement && d.activeElement !== d.body) { a = d.activeElement; continue; }
        } catch (e) { /* başka köken */ }
      }
      break;
    }
    return a;
  }
  function inside(node, anc) {
    for (let n = node; n; n = n.parentNode || n.host) if (n === anc) return true;
    return false;
  }
  function isEditHost(el) {
    const ce = el.getAttribute && el.getAttribute('contenteditable');
    return ce !== null && ce !== undefined && ce !== 'false' && !(el.parentElement && el.parentElement.isContentEditable);
  }
  function isEditable(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.isContentEditable) return true;
    if (el.localName === 'textarea') return !el.readOnly && !el.disabled;
    if (el.localName === 'input') {
      const ty = (el.getAttribute('type') || 'text').toLowerCase();
      return (TEXT_TYPES.has(ty) || DATE_TYPES.has(ty)) && !el.readOnly && !el.disabled;
    }
    return false;
  }
  function roleOf(el) {
    const r = (el.getAttribute('role') || '').trim().split(/\s+/)[0].toLowerCase();
    if (r && r !== 'presentation' && r !== 'none' && r !== 'generic') return r;
    const t = el.localName;
    if (t === 'a' || t === 'area') return el.hasAttribute('href') ? 'link' : '';
    if (t === 'button' || t === 'summary') return 'button';
    if (t === 'select') return 'select';
    if (t === 'textarea') return 'textbox';
    if (t === 'input') {
      const ty = (el.getAttribute('type') || 'text').toLowerCase();
      if (ty === 'hidden') return '';
      if (ty === 'button' || ty === 'submit' || ty === 'reset' || ty === 'image') return 'button';
      if (ty === 'checkbox') return 'checkbox';
      if (ty === 'radio') return 'radio';
      if (ty === 'range') return 'slider';
      if (ty === 'number') return 'spinbutton';
      if (ty === 'search') return 'searchbox';
      if (ty === 'file') return 'file';
      if (ty === 'color') return 'color';
      if (DATE_TYPES.has(ty)) return ty;
      return 'textbox';
    }
    if (isEditHost(el)) return 'textbox';
    if (/^h[1-6]$/.test(t)) return 'heading';
    return '';
  }
  function textOf(el) {
    return clean(el.innerText !== undefined ? el.innerText : el.textContent);
  }
  function byIds(el, attr) {
    const v = el.getAttribute(attr);
    if (!v) return '';
    const root = el.getRootNode();
    return clean(v.split(/\s+/).map((id) => {
      const x = (root && root.getElementById ? root.getElementById(id) : null) || el.ownerDocument.getElementById(id);
      return x ? textOf(x) : '';
    }).join(' '));
  }
  function accName(el, role) {
    const al = clean(el.getAttribute('aria-label'));
    if (al) return al;
    const lb = byIds(el, 'aria-labelledby');
    if (lb) return lb;
    const tag = el.localName;
    if (tag === 'label') return textOf(el);
    if (tag === 'input' || tag === 'select' || tag === 'textarea') {
      const ty = (el.getAttribute('type') || '').toLowerCase();
      if (ty === 'submit' || ty === 'button' || ty === 'reset') return clean(el.value) || (ty === 'submit' ? 'Submit' : '');
      if (ty === 'image') return clean(el.alt) || 'Submit';
      if (el.labels && el.labels.length) {
        const t = clean([...el.labels].map(textOf).join(' '));
        if (t) return t;
      }
      const ph = clean(el.getAttribute('placeholder'));
      if (ph) return ph;
      const ti = clean(el.title);
      if (ti) return ti;
      return clean(el.getAttribute('name') || '');
    }
    if (role === 'textbox' && isEditHost(el)) {
      return clean(el.getAttribute('aria-placeholder') || el.getAttribute('data-placeholder') || el.title || '');
    }
    const t = textOf(el);
    if (t) return t;
    const img = el.querySelector && el.querySelector('img[alt]');
    if (img && clean(img.alt)) return clean(img.alt);
    const st = el.querySelector && el.querySelector('svg title');
    if (st && clean(st.textContent)) return clean(st.textContent);
    return clean(el.title || el.getAttribute('data-tooltip') || '');
  }
  // Görünmeyen denetimi olan etiket (ör. display:none onay kutusu + biçimlendirilmiş etiket): etiketin kendisi tıklanır.
  function labelForHidden(el) {
    if (el.localName !== 'label' || !el.control) return false;
    const c = el.control;
    const ty = (c.type || '').toLowerCase();
    return (ty === 'checkbox' || ty === 'radio') && c.checkVisibility && !c.checkVisibility();
  }

  function describe(el, role, links) {
    let ctl = el;
    let r = role;
    if (el.localName === 'label' && el.control) { ctl = el.control; r = roleOf(ctl); }
    const id = refOf(el);
    const name = cut(clean(accName(el, r)), r === 'link' || r === 'clickable' ? 150 : 100);
    let s = `[${id}] ${r}`;
    if (name) s += ` "${q(name)}"`;
    const tag = ctl.localName;
    const ty = (ctl.getAttribute('type') || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea' || (r === 'textbox' && isEditHost(ctl))) {
      if (ty === 'password') s += ' (password)';
      if (!['checkbox', 'radio', 'file', 'button', 'submit', 'reset', 'image'].includes(ty)) {
        const v = tag === 'input' || tag === 'textarea' ? ctl.value || '' : clean(ctl.innerText);
        if (v) s += ty === 'password' ? ' value="•••"' : ` value="${q(cut(clean(v), 80))}"`;
        const ph = clean(ctl.getAttribute('placeholder'));
        if (!v && ph && ph !== name) s += ` placeholder="${q(cut(ph, 60))}"`;
      }
    }
    if (tag === 'select') {
      const o = ctl.selectedOptions && ctl.selectedOptions[0];
      if (o) s += ` value="${q(cut(clean(o.text), 60))}"`;
      const opts = [...ctl.options].map((x) => cut(clean(x.text), 40)).filter(Boolean);
      if (opts.length) s += ` options: ${opts.slice(0, 15).join(' | ')}${opts.length > 15 ? ` | …(${opts.length})` : ''}`;
    }
    if (r === 'file') {
      const n = ctl.files ? ctl.files.length : 0;
      s += n ? ` (${n} dosya seçili; dosyayı kullanıcı seçer)` : ' (dosyayı kullanıcı seçer)';
    }
    const flags = [];
    if (ctl.disabled || ctl.getAttribute('aria-disabled') === 'true') flags.push('disabled');
    if (ctl.checked === true || ctl.getAttribute('aria-checked') === 'true') flags.push('checked');
    const ex = ctl.getAttribute('aria-expanded');
    if (ex === 'true') flags.push('expanded'); else if (ex === 'false') flags.push('collapsed');
    if (ctl.getAttribute('aria-selected') === 'true') flags.push('selected');
    if (ctl.getAttribute('aria-pressed') === 'true') flags.push('pressed');
    if (ctl.required || ctl.getAttribute('aria-required') === 'true') flags.push('required');
    const cur = ctl.getAttribute('aria-current');
    if (cur && cur !== 'false') flags.push('current');
    if (flags.length) s += ` (${[...new Set(flags)].join(', ')})`;
    if (links && r === 'link' && el.href) s += ` → ${cut(String(el.href), 120)}`;
    return s;
  }

  class Out {
    constructor() { this.lines = []; this.cur = ''; this.size = 0; }
    len() { return this.size + this.cur.length; }
    text(t) { this.cur += t; }
    item(s) { this.cur += ` ${s} `; }
    flush() {
      const l = this.cur.replace(/\s+/g, ' ').replace(/^(\s*\|\s*)+|(\s*\|\s*)+$/g, '').trim();
      this.cur = '';
      if (!l || l === '-' || /^#+$/.test(l)) return;
      if (this.lines.length && this.lines[this.lines.length - 1] === l) return;
      this.lines.push(l);
      this.size += l.length + 1;
    }
  }

  function frame(el, st) {
    let doc = null;
    try { doc = el.contentDocument; } catch (e) { doc = null; }
    if (doc && doc.body) { st.out.flush(); walk(doc.body, st); st.out.flush(); return; }
    const src = el.src || el.getAttribute('src') || '';
    const cap = /recaptcha|hcaptcha|challenges\.cloudflare\.com|turnstile|arkoselabs|funcaptcha|captcha/i.test(`${src} ${el.title || ''}`);
    if (cap) st.captcha = true;
    const r = el.getBoundingClientRect();
    if (r.width < 30 || r.height < 20) return; // izleme pikselleri
    let host = '';
    try { host = new URL(src, location.href).host; } catch (e) { /* geçersiz adres */ }
    st.out.flush();
    st.out.text(cap ? '[CAPTCHA doğrulaması: kullanıcı çözmeli]' : `[çerçeve: ${host || 'iç sayfa'}, içeriği okunamıyor]`);
    st.out.flush();
  }

  function walk(node, st) {
    if (st.out.len() > LIMIT) return;
    const nt = node.nodeType;
    if (nt === 3) { if (!st.hidden) st.out.text(node.nodeValue); return; }
    if (nt === 11 || nt === 9) { for (let c = node.firstChild; c; c = c.nextSibling) walk(c, st); return; }
    if (nt !== 1) return;
    const el = node;
    if (st.skip && st.skip.has(el)) return;
    const tag = el.localName;
    if (SKIP.has(tag)) return;
    if (tag === 'slot') { for (const c of el.assignedNodes({ flatten: true })) walk(c, st); return; }
    if (tag === 'br') { st.out.flush(); return; }
    if (el.getAttribute('aria-hidden') === 'true') return;
    const cs = cssOf(el);
    if (cs.display === 'none') return;
    const contents = cs.display === 'contents';
    const control = tag === 'input' || tag === 'select' || tag === 'textarea';
    if (!contents) {
      if (el.checkVisibility && !el.checkVisibility() && !control) return;
      if (cs.opacity === '0' && !control) return;
      const r = el.getBoundingClientRect();
      if (!control && r.width <= 1 && r.height <= 1 && (cs.overflow !== 'visible' || cs.position === 'absolute')) return; // görsel olarak gizli
      const win = el.ownerDocument.defaultView || window;
      if (r.right + win.scrollX <= 0 || r.bottom + win.scrollY <= 0) return; // ekranın dışına itilmiş
    }
    const hiddenSelf = cs.visibility !== 'visible';
    // Etiketin metni denetimin adında zaten var: ayrık etiket atlanır, sarmalayan etiketten yalnızca denetim yazılır.
    if (tag === 'label' && el.control && !labelForHidden(el)) {
      if (el.contains(el.control)) walk(el.control, st);
      return;
    }
    const role = roleOf(el);
    const pointer = cs.cursor === 'pointer';
    if (!hiddenSelf) {
      if (ACTION_ROLES.has(role) || el.hasAttribute('onclick') || labelForHidden(el)) {
        st.out.item(describe(el, role || 'clickable', st.links));
        return;
      }
      // İmleci el olan en dıştaki öğe (div/satır/kart gibi; tıklama işleyicisi betikle bağlanmış olabilir).
      if (pointer && !st.pointer && tag !== 'label' && tag !== 'body' && tag !== 'html') {
        const inner = el.querySelectorAll(ACTION_SEL);
        if (!inner.length) {
          if (accName(el, '')) { st.out.item(describe(el, 'clickable', st.links)); return; }
        } else if (inner.length <= 20) {
          // İçinde düğmeler de olan tıklanabilir satır (ör. e-posta listesi): satırın kendi metni yeterliyse işaretle.
          const own = textOf(el).length - [...inner].reduce((n, x) => n + textOf(x).length, 0);
          if (own >= 15) st.out.item(`[${refOf(el)}] clickable:`);
        }
      }
    }
    const block = !contents && BLOCKY.test(cs.display);
    if (block) st.out.flush();
    if (cs.display === 'table-cell') st.out.text(' | ');
    if (role === 'heading' && !hiddenSelf) {
      st.out.flush();
      const lvl = Number(tag[1]) || Number(el.getAttribute('aria-level')) || 2;
      st.out.text(`${'#'.repeat(Math.min(3, lvl))} `);
    }
    if (tag === 'li' && !hiddenSelf) st.out.text('- ');
    const prevHidden = st.hidden;
    const prevPointer = st.pointer;
    st.hidden = hiddenSelf;
    st.pointer = pointer;
    if (tag === 'iframe' || tag === 'frame') frame(el, st);
    else if (el.shadowRoot) walk(el.shadowRoot, st);
    else for (let c = el.firstChild; c; c = c.nextSibling) walk(c, st);
    st.hidden = prevHidden;
    st.pointer = prevPointer;
    if (block || role === 'heading') st.out.flush();
  }

  function run(root, opt, skip) {
    const st = { out: new Out(), links: !!opt.links, pointer: false, hidden: false, skip, captcha: false };
    walk(root, st);
    st.out.flush();
    return { text: st.out.lines.join('\n'), captcha: st.captcha };
  }

  // Açık iletişim kutusu (çerez bildirimi, açılır pencere): önce o gösterilir.
  function modalRoot() {
    let best = null;
    for (const d of document.querySelectorAll('dialog[open], [aria-modal="true"], [role="dialog"], [role="alertdialog"]')) {
      const cs = cssOf(d);
      if (cs.display === 'none' || cs.visibility !== 'visible' || cs.opacity === '0') continue;
      const r = d.getBoundingClientRect();
      if (r.width < 50 || r.height < 30) continue;
      if (d.checkVisibility && !d.checkVisibility()) continue;
      if (!best || best.contains(d) || (best.compareDocumentPosition(d) & Node.DOCUMENT_POSITION_FOLLOWING)) best = d;
    }
    return best;
  }

  function info(el) {
    const ctl = el.localName === 'label' && el.control ? el.control : el;
    const role = roleOf(ctl) || 'clickable';
    const attrs = [ctl.id, ctl.getAttribute('name'), ctl.getAttribute('placeholder'), ctl.getAttribute('aria-label'), byIds(ctl, 'aria-labelledby'),
      ctl.labels ? [...ctl.labels].map(textOf).join(' ') : '', ctl.getAttribute('data-testid'), ctl.getAttribute('formcontrolname'),
      ctl.getAttribute('inputmode'), ctl.getAttribute('title')].filter(Boolean).join(' ').toLowerCase();
    return {
      tag: ctl.localName,
      role,
      name: cut(clean(accName(el, role)), 200),
      type: (ctl.getAttribute('type') || (ctl.localName === 'input' ? 'text' : '')).toLowerCase(),
      autocomplete: (ctl.getAttribute('autocomplete') || '').toLowerCase(),
      attrs,
      href: el.href ? String(el.href) : '',
      editable: isEditable(ctl),
      multiline: ctl.localName === 'textarea' || !!ctl.isContentEditable,
      host: location.host,
      path: location.pathname + location.search,
    };
  }

  function editRoot(el) {
    let r = el;
    while (r.parentElement && r.parentElement.isContentEditable) r = r.parentElement;
    return r;
  }

  function scrollParent(el) {
    for (let n = el; n && n !== document.body && n !== document.documentElement; n = n.parentElement || (n.getRootNode() && n.getRootNode().host)) {
      if (n.nodeType !== 1) continue;
      const cs = cssOf(n);
      if (/(auto|scroll|overlay)/.test(cs.overflowY) && n.scrollHeight > n.clientHeight + 4) return n;
    }
    return null;
  }

  function setNative(el, v) {
    const proto = el.localName === 'textarea' ? HTMLTextAreaElement.prototype : el.localName === 'select' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    const d = Object.getOwnPropertyDescriptor(proto, 'value');
    if (d && d.set) d.set.call(el, v); else el.value = v;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  globalThis.__fr = {
    snapshot(opt) {
      opt = opt || {};
      const body = document.body || document.documentElement;
      if (!body) return { title: document.title || '', url: location.href, text: '', captcha: false };
      const parts = [];
      let captcha = false;
      const dlg = modalRoot();
      if (dlg && dlg !== body) {
        const a = run(dlg, opt, null);
        const b = run(body, opt, new Set([dlg]));
        if (a.text) parts.push(`## [Açık pencere]\n${a.text}`);
        if (b.text) parts.push(a.text ? `## [Sayfanın geri kalanı]\n${b.text}` : b.text);
        captcha = a.captcha || b.captcha;
      } else {
        const a = run(body, opt, null);
        parts.push(a.text);
        captcha = a.captcha;
      }
      const title = document.title || '';
      captcha = captcha || /^(just a moment|bir dakika|attention required|verify you are human)/i.test(title) ||
        !!document.querySelector('.g-recaptcha, .h-captcha, .cf-turnstile, #challenge-form');
      const act = deepActive();
      return {
        title,
        url: location.href,
        text: parts.join('\n\n'),
        captcha,
        focus: act && act !== document.body && isEditable(act) ? refOf(act) : null,
        scroll: { y: Math.round(scrollY), h: Math.round(document.documentElement.scrollHeight), vh: innerHeight },
      };
    },
    find(query) {
      const qq = fold(query);
      const s = this.snapshot({});
      const hits = [];
      for (const line of s.text.split('\n')) {
        const f = fold(line);
        const i = f.indexOf(qq);
        if (i < 0) continue;
        hits.push(line.length > 320 ? `…${line.slice(Math.max(0, i - 150), i + 170)}…` : line);
        if (hits.length >= 25) break;
      }
      return { title: s.title, url: s.url, hits };
    },
    info(n) {
      const el = byRef(n);
      return el ? info(el) : null;
    },
    active() {
      const a = deepActive();
      return a && a !== document.body && a !== document.documentElement ? info(a) : null;
    },
    // Öğeyi görünür alana getirir ve tıklanacak noktayı (ana çerçeve koordinatı, CSS pikseli) döndürür.
    point(n) {
      const el = byRef(n);
      if (!el) return { err: 'gone' };
      let target = el;
      let r = el.getBoundingClientRect();
      if ((r.width < 1 || r.height < 1) && el.labels && el.labels.length) target = el.labels[0];
      target.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      r = target.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return { err: 'nobox' };
      let ox = 0;
      let oy = 0;
      try {
        for (let w = target.ownerDocument.defaultView; w && w.frameElement; w = w.parent) {
          const fe = w.frameElement;
          const fr = fe.getBoundingClientRect();
          ox += fr.left + fe.clientLeft;
          oy += fr.top + fe.clientTop;
        }
      } catch (e) { /* başka köken */ }
      const doc = target.ownerDocument;
      const vw = doc.defaultView.innerWidth;
      const vh = doc.defaultView.innerHeight;
      const ok = (hit) => hit && (inside(hit, target) || inside(target, hit) || (el.labels && [...el.labels].some((l) => inside(hit, l))));
      let cover = null;
      for (const [fx, fy] of [[0.5, 0.5], [0.3, 0.5], [0.7, 0.5], [0.5, 0.3], [0.5, 0.7], [0.15, 0.2], [0.85, 0.8]]) {
        const x = r.left + r.width * fx;
        const y = r.top + r.height * fy;
        if (x < 0 || y < 0 || x >= vw || y >= vh) continue;
        let hit = doc.elementFromPoint(x, y);
        for (let i = 0; i < 10 && hit && hit.shadowRoot; i++) {
          const inner = hit.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === hit) break;
          hit = inner;
        }
        if (ok(hit)) return { x: x + ox, y: y + oy };
        if (!cover && hit) cover = cut(`${hit.localName}${hit.id ? `#${hit.id}` : ''} "${clean(accName(hit, roleOf(hit)))}"`, 120);
      }
      return { err: 'covered', by: cover || '?' };
    },
    // Yazmadan önce: odaktaki yazı alanını (tıklama odağı site içinde başka bir alana taşımış olabilir; yoksa ya da
    // `force` ise numaralı öğeyi) seçer ve gerçek hedefin bilgisini döndürür.
    prepType(n, force) {
      let el = deepActive();
      const t = byRef(n);
      if (force || !isEditable(el)) {
        if (!t) return { err: 'gone' };
        let x = isEditable(t) ? t : t.querySelector && t.querySelector('input:not([type=hidden]),textarea,[contenteditable]:not([contenteditable=false])');
        if (!x && t.localName === 'label' && t.control) x = t.control;
        if (!x || !isEditable(x)) return { err: 'noedit' };
        x.focus();
        el = x;
      }
      try {
        if (el.localName === 'input' || el.localName === 'textarea') el.select();
        else {
          const d = el.ownerDocument;
          const sel = d.getSelection();
          const rg = d.createRange();
          rg.selectNodeContents(editRoot(el));
          sel.removeAllRanges();
          sel.addRange(rg);
        }
      } catch (e) { /* seçim desteklenmiyor */ }
      return { ok: true, ref: refOf(el), date: el.localName === 'input' && DATE_TYPES.has((el.type || '').toLowerCase()), info: info(el) };
    },
    setValue(n, v) {
      const el = byRef(n);
      if (!el) return { err: 'gone' };
      setNative(el, v);
      return { ok: true, value: el.value };
    },
    value(n) {
      const el = byRef(n);
      if (!el) return null;
      if (el.localName === 'input' && (el.type || '').toLowerCase() === 'password') return el.value ? '•••' : '';
      return cut(el.localName === 'input' || el.localName === 'textarea' ? el.value || '' : textOf(el), 300);
    },
    select(n, v) {
      const el = byRef(n);
      if (!el) return { err: 'gone' };
      if (el.localName !== 'select') return { err: 'notselect' };
      const want = fold(clean(v));
      const opts = [...el.options];
      const o = opts.find((x) => x.value === v) || opts.find((x) => fold(clean(x.text)) === want) || opts.find((x) => fold(clean(x.text)).includes(want));
      if (!o) return { err: 'nooption', options: opts.slice(0, 40).map((x) => clean(x.text)) };
      el.focus();
      setNative(el, o.value);
      return { ok: true, text: clean(o.text) };
    },
    scroll(n, dir) {
      const sign = dir === 'up' ? -1 : 1;
      const el = n ? byRef(n) : null;
      let sc = el ? scrollParent(el) || (el.scrollHeight > el.clientHeight + 4 ? el : null) : null;
      if (!sc) {
        const se = document.scrollingElement || document.documentElement;
        const pageCanScroll = se.scrollHeight > innerHeight + 4;
        if (!pageCanScroll) {
          const c = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
          sc = c ? scrollParent(c) : null;
        }
      }
      const page = !sc;
      const before = page ? scrollY : sc.scrollTop;
      const amount = Math.round((page ? innerHeight : sc.clientHeight) * 0.8) * sign;
      if (page) window.scrollBy(0, amount); else sc.scrollBy(0, amount);
      const after = page ? scrollY : sc.scrollTop;
      return { moved: Math.round(after - before) };
    },
    // DOM bir süre değişmeyince (ya da en geç `max` ms sonra) çözülür: tek sayfalık uygulamaların çizimi bitsin.
    quiet(ms, max) {
      return new Promise((resolve) => {
        const start = performance.now();
        let last = start;
        const mo = new MutationObserver(() => { last = performance.now(); });
        try { mo.observe(document, { subtree: true, childList: true, characterData: true }); } catch (e) { resolve(false); return; }
        const tick = () => {
          const now = performance.now();
          if (now - last >= ms || now - start >= max) { mo.disconnect(); resolve(now - start < max); } else setTimeout(tick, 50);
        };
        setTimeout(tick, 50);
      });
    },
    ready() { return document.readyState; },
    viewport() { return { w: innerWidth, h: innerHeight, dpr: devicePixelRatio }; },
  };
})();
