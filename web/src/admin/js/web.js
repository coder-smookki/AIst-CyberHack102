(function () {
  'use strict';
  var KV = window.KV;
  var D = KV.data;
  var Q = new URLSearchParams(location.search);
  var RM = (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches) || Q.get('motion') === '0';
  var EASE = 'cubic-bezier(0.2, 0.8, 0.2, 1)';
  var EASE_OUT = 'cubic-bezier(0.2, 0, 0, 1)';
  var T = { swap: 280, fade: 260, drawer: 340, modal: 220, close: 200, toast: 3200 };
  var W = KV.w = KV.w || {};
  var DESK_W = 1440, DESK_H = 900;
  W.SIZE = { w: DESK_W, h: DESK_H };
  function P() { return Promise.resolve(); }
  function dur(ms) { return RM ? 0 : ms; }
  function slice(l) { return Array.prototype.slice.call(l || []); }
  function rm(n) { if (n && n.parentNode) n.parentNode.removeChild(n); }
  function h(tag, cls, html) { var e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; }
  function anim(el, frames, ms, easing, extra) {
    if (!el || !el.animate) return P();
    var o = { duration: dur(ms), easing: easing || EASE, fill: 'both' };
    if (extra) for (var k in extra) o[k] = extra[k];
    var a = el.animate(frames, o);
    return a.finished.then(function () { return a; }, function () { return a; });
  }
  function settle(a) { if (a && a.cancel) a.cancel(); }
  var esc = KV.esc, icon = KV.icon;
  KV.ICONS.expand = '<path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7"/>';
  KV.ICONS.cmd = '<path d="M9 6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3z"/>';
  KV.ICONS.rollback = '<path d="M4 9h11a5 5 0 0 1 0 10H8"/><path d="M8 5 4 9l4 4"/>';
  KV.ICONS.chip = '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2.5v3.5M15 2.5v3.5M9 18v3.5M15 18v3.5M2.5 9H6M2.5 15H6M18 9h3.5M18 15h3.5"/>';
  KV.ICONS.image = '<rect x="3.5" y="4.5" width="17" height="15" rx="3"/><circle cx="9" cy="10" r="1.8"/><path d="m4 17 5-4.5 4 3.5 3-2.5 4 3.5"/>';
  function chainOf(id) {
    var c = [], d = KV.screens[id], guard = 0;
    while (d && d.base && guard++ < 8) { c.unshift(d.id); d = d.over ? KV.screens[d.over] : null; }
    return c;
  }
  function baseOf(id) { var c = chainOf(id); return c.length ? KV.screens[c[0]].base : id; }
  W.chainOf = chainOf; W.baseOf = baseOf;
  function markStagger(el) {
    var body = el.querySelector('.wmain-in');
    var i = 0;
    if (body) slice(body.children).forEach(function (c) { if (i < 10) { c.classList.add('stg'); c.style.setProperty('--i', i++); } });
  }
  function playAppear(el) {
    if (RM || !el) return;
    el.classList.remove('is-appearing', 'is-drawing'); void el.offsetWidth;
    el.classList.add('is-appearing', 'is-drawing');
    clearTimeout(el.__appearT);
    el.__appearT = setTimeout(function () { el.classList.remove('is-appearing', 'is-drawing'); }, 1500);
  }
  function deskTypo(root) {
    if (!root || !document.createTreeWalker) return;
    var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null), n;
    while ((n = w.nextNode())) if (n.nodeValue.indexOf('№ ') >= 0) n.nodeValue = n.nodeValue.replace(/№ /g, '№\u00A0');
  }
  W.typo = function (root) { KV.typo(root); deskTypo(root); };
  function buildOvl(def, o) {
    var ctx = KV.ctxFor(def, o);
    var ovl = h('div', 'ovl wovl');
    try { ovl.innerHTML = def.render(ctx); } catch (e) { console.error('render ' + def.id, e); ovl.innerHTML = W.toast({ kind: 'bad', title: 'Ошибка отрисовки', text: String(e.message) }); }
    var kind = ovl.querySelector('.wdrawer') ? 'drawer' : ovl.querySelector('.wtoast') ? 'toast' : 'modal';
    ovl.dataset.overlay = def.id; ovl.dataset.kind = kind;
    ovl.classList.add('is-' + kind);
    if (kind !== 'toast') ovl.insertBefore(h('div', 'ovl-scrim wscrim'), ovl.firstChild).setAttribute('data-close', '1');
    W.typo(ovl);
    if (def.after) try { def.after(ovl, ctx); } catch (e2) { console.error('after ' + def.id, e2); }
    return ovl;
  }
  KV.buildDesk = function (id, o) {
    o = o || {};
    var def = KV.screens[id];
    if (!def) { var miss = h('div', 'scr wscr'); miss.innerHTML = '<div class="wgrow">' + W.empty({ icon: 'info', title: 'Нет экрана', text: id }) + '</div>'; return miss; }
    var chain = chainOf(id);
    if (chain.length) {
      var root = KV.screens[chain[0]];
      var base = KV.buildDesk(root.base, { theme: o.theme, w: o.w, h: o.h, phone: o.phone, solo: o.solo, params: root.baseParams });
      chain.forEach(function (cid) { base.appendChild(buildOvl(KV.screens[cid], o)); });
      return base;
    }
    var ctx = KV.ctxFor(def, o);
    var el = h('div', KV.cls('scr wscr', def.cls));
    try { el.innerHTML = def.render(ctx); } catch (e) { console.error('render ' + id, e); el.innerHTML = '<div class="wgrow">' + W.empty({ icon: 'alert', title: 'Ошибка отрисовки', text: String(e.message) }) + '</div>'; }
    el.dataset.screen = id;
    W.typo(el);
    markStagger(el);
    if (def.after) try { def.after(el, ctx); } catch (e2) { console.error('after ' + id, e2); }
    return el;
  };
  function Desk(vp, o) {
    this.vp = vp; vp.__phone = this; vp.__desk = this;
    this.o = o; this.initial = o.id;
    this.stack = []; this.ovls = []; this.busy = false;
    this.mount(o.id, false);
    if (KV.allPhones) KV.allPhones.push(this);
    if (!KV.activeDesk) KV.activeDesk = this;
  }
  Object.defineProperty(Desk.prototype, 'ovl', { get: function () { return this.ovls[this.ovls.length - 1] || null; } });
  Desk.prototype.opts = function () { return { theme: this.o.theme, w: this.o.w, h: this.o.h, phone: this, solo: this.o.solo }; };
  Desk.prototype.top = function () { return this.stack[this.stack.length - 1]; };
  Desk.prototype.changed = function () { if (this.o.onChange) this.o.onChange(this); };
  Desk.prototype.currentId = function () { var o = this.ovls[this.ovls.length - 1]; return o && o.kind !== 'toast' ? o.id : (this.top() && this.top().id); };
  Desk.prototype.isInitial = function () {
    var ch = chainOf(this.initial), ov = this.ovls;
    return this.stack.length === 1 && this.stack[0].id === baseOf(this.initial) && ov.length === ch.length && ov.every(function (x, i) { return x.id === ch[i]; });
  };
  Desk.prototype.mount = function (id, animated) {
    var old = slice(this.vp.children);
    var el = KV.buildDesk(id, this.opts());
    this.vp.appendChild(el);
    KV.layoutSegs(el);
    this.stack = [{ id: baseOf(id), el: el }];
    this.ovls = slice(el.querySelectorAll(':scope > .wovl')).map(function (n) { return { id: n.dataset.overlay, el: n, kind: n.dataset.kind, static: true }; });
    if (animated) { anim(el, [{ opacity: 0 }, { opacity: 1 }], T.fade, EASE_OUT).then(function () { old.forEach(rm); }); playAppear(el); }
    else old.forEach(rm);
    this.changed();
  };
  Desk.prototype.reset = function () { this.busy = false; this.mount(this.initial, true); };
  Desk.prototype.go = function (id, nav) {
    var self = this, def = KV.screens[id];
    if (!def) { console.warn('KV: no screen "' + id + '"'); return P(); }
    if (this.busy) return P();
    var chain = chainOf(id), base = baseOf(id), top = this.top();
    if (!top || top.id !== base) {
      return this.closeTo(0, true).then(function () { return self.swap(base, nav); }).then(function () { return self.openChain(chain, 0); });
    }
    if (!chain.length) return this.closeTo(0);
    var k = 0;
    while (k < this.ovls.length && k < chain.length && this.ovls[k].id === chain[k]) k++;
    if (k === chain.length) return this.closeTo(k);
    return this.closeTo(k + 1, true).then(function () {
      var cur = self.ovls[k];
      if (!cur) return self.openChain(chain, k);
      var ovl = buildOvl(KV.screens[chain[k]], self.opts());
      if (ovl.dataset.kind !== 'toast' && cur.kind === ovl.dataset.kind) return self.swapOvl(k, ovl).then(function () { return self.openChain(chain, k + 1); });
      return self.closeTo(k, true).then(function () { return self.openChain(chain, k, ovl); });
    });
  };
  Desk.prototype.openChain = function (chain, from, prebuilt) {
    var self = this, p = P();
    chain.forEach(function (cid, i) {
      if (i < from) return;
      p = p.then(function () {
        var ovl = (i === from && prebuilt) || buildOvl(KV.screens[cid], self.opts());
        return self.openOvl(ovl, i === chain.length - 1);
      });
    });
    return p;
  };
  Desk.prototype.openOvl = function (ovl, animate) {
    var self = this, top = this.top(), kind = ovl.dataset.kind;
    if (kind === 'toast') { this.transient(ovl); return P(); }
    top.el.appendChild(ovl);
    KV.layoutSegs(ovl);
    this.ovls.push({ id: ovl.dataset.overlay, el: ovl, kind: kind });
    var focus = ovl.querySelector('[data-autofocus]');
    if (!animate || RM) { this.changed(); if (focus && this.o.solo) focus.focus(); return P(); }
    this.busy = true;
    var scrim = ovl.querySelector('.wscrim'), box = ovl.querySelector('.wdrawer, .wmodal');
    var ps = [anim(scrim, [{ opacity: 0 }, { opacity: 1 }], 220, EASE_OUT)];
    if (kind === 'drawer') ps.push(anim(box, [{ transform: 'translateX(104%)' }, { transform: 'none' }], T.drawer, EASE));
    else ps.push(anim(box, [{ opacity: 0, transform: 'scale(.97) translateY(6px)' }, { opacity: 1, transform: 'none' }], T.modal, EASE));
    playAppear(ovl);
    return Promise.all(ps).then(function (r) {
      r.forEach(settle); self.busy = false; self.changed();
      if (focus && document.activeElement && self.vp.contains(document.activeElement) === false && KV.activeDesk === self) { try { focus.focus({ preventScroll: true }); } catch (e) {  } }
    });
  };
  Desk.prototype.hideOvl = function (o, fast) {
    var d = fast ? 150 : T.close;
    if (o.kind === 'toast') return anim(o.el, [{ opacity: 1 }, { opacity: 0 }], d, EASE_OUT).then(function () { rm(o.el); });
    var scrim = o.el.querySelector('.wscrim'), box = o.el.querySelector('.wdrawer, .wmodal');
    return Promise.all([
      anim(scrim, [{ opacity: 1 }, { opacity: 0 }], d, EASE_OUT),
      anim(box, o.kind === 'drawer' ? [{ transform: 'none' }, { transform: 'translateX(104%)' }] : [{ opacity: 1, transform: 'none' }, { opacity: 0, transform: 'scale(.98)' }], d, EASE_OUT)
    ]).then(function () { rm(o.el); });
  };
  Desk.prototype.closeTo = function (n, fast) {
    var self = this, gone = [];
    while (this.ovls.length > n) gone.push(this.ovls.pop());
    if (!gone.length) return P();
    this.busy = true;
    return Promise.all(gone.map(function (o) { return self.hideOvl(o, fast); })).then(function () { self.busy = false; self.changed(); });
  };
  Desk.prototype.closeOverlay = function (fast) {
    if (this.busy || !this.ovls.length) return P();
    return this.closeTo(this.ovls.length - 1, fast);
  };
  Desk.prototype.swapOvl = function (k, ovl) {
    var self = this, old = this.ovls[k];
    old.el.parentNode.insertBefore(ovl, old.el.nextSibling);
    KV.layoutSegs(ovl);
    this.ovls[k] = { id: ovl.dataset.overlay, el: ovl, kind: ovl.dataset.kind };
    var os = old.el.querySelector('.wscrim'); if (os) os.style.opacity = '0';
    this.busy = true;
    var box = ovl.querySelector('.wdrawer, .wmodal'), oldBox = old.el.querySelector('.wdrawer, .wmodal');
    return Promise.all([
      anim(box, [{ opacity: 0, transform: ovl.dataset.kind === 'drawer' ? 'translateX(14px)' : 'translateY(6px)' }, { opacity: 1, transform: 'none' }], 240, EASE_OUT),
      anim(oldBox, [{ opacity: 1 }, { opacity: 0 }], 140, EASE_OUT)
    ]).then(function (r) { rm(old.el); settle(r[0]); self.busy = false; self.changed(); });
  };
  Desk.prototype.swap = function (id, nav) {
    var self = this, top = this.top();
    var el = KV.buildDesk(id, this.opts());
    var shell = el.querySelector(':scope > .wside') && top.el.querySelector(':scope > .wside') && nav !== 'fade';
    this.vp.appendChild(el);
    KV.layoutSegs(el);
    this.busy = true;
    var ps;
    if (shell) {
      var parts = slice(el.querySelectorAll(':scope > .wmain > *'));
      ps = parts.map(function (p, i) { return anim(p, [{ opacity: 0, transform: 'translateY(6px)' }, { opacity: 1, transform: 'none' }], T.swap, EASE_OUT, { delay: dur(Math.min(i, 3) * 30) }); });
      slidePill(top.el, el);
      if (!RM) { el.classList.add('is-drawing'); setTimeout(function () { el.classList.remove('is-drawing'); }, 1300); }
    } else {
      ps = [anim(el, [{ opacity: 0 }, { opacity: 1 }], T.fade, EASE_OUT)];
      playAppear(el);
    }
    return Promise.all(ps).then(function (r) {
      r.forEach(settle); rm(top.el);
      var entry = { id: id, el: el };
      if (nav === 'push') self.stack.push(entry);
      else if (nav === 'back') { self.stack.pop(); self.stack[self.stack.length - 1] = entry; }
      else self.stack = [entry];
      self.busy = false; self.changed();
    });
  };
  function slidePill(oldEl, newEl) {
    if (RM) return;
    var a = oldEl.querySelector('.wnav-item.is-on'), b = newEl.querySelector('.wnav-item.is-on');
    if (!a || !b || a.dataset.nav === b.dataset.nav) return;
    var ghost = h('span', 'wnav-ghost');
    ghost.style.top = b.offsetTop + 'px'; ghost.style.height = b.offsetHeight + 'px';
    b.parentNode.appendChild(ghost);
    b.classList.add('no-pill');
    anim(ghost, [{ transform: 'translateY(' + (a.offsetTop - b.offsetTop) + 'px)' }, { transform: 'none' }], 320, EASE).then(function () { b.classList.remove('no-pill'); rm(ghost); });
  }
  Desk.prototype.back = function (fallback) {
    if (this.busy) return P();
    if (this.ovls.length) return this.closeOverlay();
    if (this.stack.length > 1) return this.swap(this.stack[this.stack.length - 2].id, 'back');
    if (fallback && KV.screens[fallback]) return this.go(fallback);
    return P();
  };
  Desk.prototype.transient = function (ovl) {
    var top = this.top();
    slice(top.el.querySelectorAll(':scope > .wovl.transient')).forEach(rm);
    ovl.classList.add('transient');
    top.el.appendChild(ovl);
    var box = ovl.querySelector('.wtoast');
    anim(box, [{ opacity: 0, transform: 'translateY(-10px)' }, { opacity: 1, transform: 'none' }], 260, EASE);
    setTimeout(function () { anim(box, [{ opacity: 1 }, { opacity: 0, transform: 'translateY(-6px)' }], 220, EASE_OUT).then(function () { rm(ovl); }); }, T.toast);
  };
  Desk.prototype.toast = function (title, text, kind, icn) {
    var ovl = h('div', 'ovl wovl is-toast', W.toast({ kind: kind || 'ok', title: title, text: text, icon: icn }));
    ovl.dataset.kind = 'toast';
    W.typo(ovl);
    this.transient(ovl);
  };
  Desk.prototype.snack = function (text) { this.toast(text, '', 'ok'); };
  KV.Desk = Desk;
  KV.createDeskMock = function (o) {
    var def = KV.screens[o.id] || { title: o.id, role: 'all' };
    var mode = o.theme || 'auto';
    var theme = mode === 'auto' ? (KV.getBoardTheme ? KV.getBoardTheme() : 'light') : mode;
    var mock = h('div', 'mock wmock');
    var dev = h('div', 'wdev');
    dev.innerHTML = '<div class="wdev-bar"><span class="wdev-dots"><i></i><i></i><i></i></span><span class="wdev-url">' + icon('lock', 12) + '10.20.4.15:8000/panel</span></div>';
    var scr = h('div', 'device-screen wdev-screen'); scr.style.width = DESK_W + 'px'; scr.style.height = DESK_H + 'px'; scr.setAttribute('data-theme', theme);
    var vp = h('div', 'device-vp wdev-vp');
    scr.appendChild(vp); dev.appendChild(scr); mock.appendChild(dev);
    var cap = h('div', 'mock-cap');
    var role = KV.ROLES[o.role || def.role] || KV.ROLES.all;
    cap.innerHTML = (o.num ? '<span class="mock-num">' + o.num + '</span>' : '') +
      '<div class="mock-cap-text"><b>' + esc(o.title || def.title || o.id) + '</b><span>' + esc(o.sub != null ? o.sub : (def.caption || role.label + ' · веб-панель')) + '</span></div>';
    var open = h('a', 'mock-open', icon('expand', 16)); open.title = 'Открыть окно в полном размере'; open.setAttribute('aria-label', 'Открыть окно в полном размере'); open.target = '_blank'; open.rel = 'noopener';
    var rb = h('button', 'mock-reset', icon('refresh', 18)); rb.title = 'Вернуть исходный экран'; rb.setAttribute('aria-label', 'Вернуть исходный экран');
    cap.appendChild(open); cap.appendChild(rb);
    mock.appendChild(cap);
    var ph = new Desk(vp, { id: o.id, theme: theme, themeMode: mode, w: DESK_W, h: DESK_H, onChange: function (p) { rb.classList.toggle('is-on', !p.isInitial()); if (o.onChange) o.onChange(p); } });
    var setHref = function () { open.href = location.pathname + '?screen=' + encodeURIComponent(ph.currentId()) + '&theme=' + (scr.getAttribute('data-theme') || 'light'); };
    setHref();
    open.addEventListener('pointerdown', setHref); open.addEventListener('focus', setHref);
    rb.addEventListener('click', function () { ph.reset(); });
    mock.__phone = ph;
    return mock;
  };
  var secIdx = -1;
  KV.SECTIONS.forEach(function (s, i) { if (s.id === 'sec') secIdx = i; });
  KV.SECTIONS.splice(secIdx + 1, 0, { id: 'web', title: 'Веб-панель администратора',
    sub: 'Сервер КСТ-СРВ-02 в браузере · Админ: система, оборудование, телеметрия и сценарии, модели, журнал · Админ ИБ: учётные записи, роли, политика, журнал безопасности · окна живые, ⌘K - быстрый поиск, Esc закрывает панель' });
  function deskZoom() {
    var row = document.querySelector('#sec-web .board-row');
    if (!row) return;
    var w = row.clientWidth, fw = DESK_W + 2;
    var z = (w - 40) / (2 * fw);
    if (z < 0.42) z = w / fw;
    document.documentElement.style.setProperty('--desk-zoom', Math.min(0.8, z).toFixed(3));
  }
  document.addEventListener('DOMContentLoaded', function () {
    if (!document.documentElement.classList.contains('board')) return;
    deskZoom();
    window.addEventListener('resize', deskZoom);
  });
  document.addEventListener('pointerdown', function (e) {
    var vp = e.target.closest && e.target.closest('.wdev-vp, .solo-vp');
    if (vp && vp.__desk) KV.activeDesk = vp.__desk;
  }, true);
  document.addEventListener('keydown', function (e) {
    var d = KV.activeDesk;
    if (!d || !document.contains(d.vp)) return;
    if (e.key === 'Escape' && d.ovls.length) { e.preventDefault(); d.closeOverlay(); return; }
    if ((e.metaKey || e.ctrlKey) && /^[kKлЛ]$/.test(e.key)) {
      var b = d.top() && d.top().el.querySelector('[data-cmdk]');
      if (b) { e.preventDefault(); d.go(b.getAttribute('data-go')); }
    }
  });
  document.addEventListener('click', function (e) {
    var t = e.target.closest && e.target.closest('[data-weye]');
    if (!t) return;
    var inp = t.parentNode.querySelector('input');
    if (!inp) return;
    var show = inp.type === 'password';
    inp.type = show ? 'text' : 'password';
    t.innerHTML = icon(show ? 'eyeOff' : 'eye', 18);
    t.setAttribute('aria-label', show ? 'Скрыть пароль' : 'Показать пароль');
  });
  W.screen = function (def) {
    def.desktop = true;
    def.section = def.section || 'web';
    def.board = def.board === true || (def.board !== false && !def.base);
    if (!def.caption) def.caption = ((KV.ROLES[def.role] || KV.ROLES.all).label) + ' · веб-панель';
    return KV.screen(def);
  };
  W.page = function (def) {
    W.screen(def);
    if (W.PERSON[def.role]) {
      W.screen({ id: def.id + '-cmdk', base: def.id, title: 'Быстрый поиск', role: def.role, order: def.order + 0.5, board: false, render: function () { return W.cmdk(def.role); }, after: W.cmdkAfter });
      W.screen({ id: def.id + '-notif', base: def.id, title: 'Уведомления', role: def.role, order: def.order + 0.6, board: false, render: function () { return W.notif(def.role); } });
      if (def.role === 'admin') {
        W.screen({ id: def.id + '-update', base: def.id, title: 'Обновление сервера', role: def.role, order: def.order + 0.7, board: false, render: function () { return W.updateModal(def.id); } });
        W.screen({ id: def.id + '-update-later', base: def.id, title: 'Обновление запланировано', role: def.role, order: def.order + 0.71, board: false,
          render: function () { return W.toast({ kind: 'ok', icon: 'calendar', title: 'Обновление 1.5.0 запланировано', text: 'Сегодня ночью в 03:30, после резервной копии. Сотрудники получат уведомление.' }); } });
        W.screen({ id: def.id + '-update-run', base: def.id, title: 'Обновление загружено', role: def.role, order: def.order + 0.72, board: false,
          render: function () { return W.toast({ kind: 'info', icon: 'download', title: 'Обновление загружено и проверено', text: 'Резервная копия создаётся, затем сервер перезапустится. Около 2 мин.' }); } });
      }
    }
    return def;
  };
  function act(o) { return KV.act(o); }
  W.act = act;
  W.btn = function (text, o) {
    o = o || {};
    var c = KV.cls('wbtn', o.kind || 'secondary', o.size, o.wide && 'wide', !text && 'icon', o.cls, o.loading && 'is-loading');
    return '<button class="' + c + '" ' + act(o) + (o.disabled ? ' disabled' : '') + (o.label ? ' aria-label="' + esc(o.label) + '"' : '') + (o.title ? ' title="' + esc(o.title) + '"' : '') + '>' +
      (o.icon ? icon(o.icon, 18) : '') + (text ? '<span>' + esc(text) + '</span>' : '') + (o.kbd ? '<span class="wbtn-k">' + esc(o.kbd) + '</span>' : '') + (o.iconRight ? icon(o.iconRight, 18) : '') + (o.badge ? '<i class="wbtn-badge"></i>' : '') + '</button>';
  };
  W.ibtn = function (ic, o) { o = o || {}; o.icon = ic; return W.btn('', o); };
  W.link = function (text, o) { return '<button class="wlink" ' + act(o) + '>' + esc(text) + (o && o.arrow ? icon('arrowRight', 14) : '') + '</button>'; };
  W.field = function (o) {
    o = o || {};
    var inp = o.area ? '<textarea' + (o.name ? ' name="' + esc(o.name) + '"' : '') + ' placeholder="' + esc(o.placeholder || '') + '"' + (o.attrs ? ' ' + o.attrs : '') + '>' + esc(o.value || '') + '</textarea>'
      : '<input type="' + (o.type || 'text') + '"' + (o.name ? ' name="' + esc(o.name) + '"' : '') + ' value="' + esc(o.value || '') + '" placeholder="' + esc(o.placeholder || '') + '"' + (o.ro ? ' readonly' : '') + (o.mono ? ' class="wmono"' : '') + (o.attrs ? ' ' + o.attrs : '') + ' autocomplete="off" spellcheck="false">';
    var box = '<span class="' + KV.cls('winput', o.lg && 'lg', o.ro && 'ro', o.area && 'area', o.error && 'is-error', o.focus && 'is-focus') + '">' + (o.lead ? icon(o.lead, 18) : '') + inp + (o.suffix ? '<span class="wsuffix">' + esc(o.suffix) + '</span>' : '') + (o.end || '') + '</span>';
    return '<label class="wfield' + (o.cls ? ' ' + o.cls : '') + '">' + (o.label ? '<span class="wfield-l"><span>' + esc(o.label) + '</span>' + (o.hint || '') + '</span>' : '') + box +
      (o.help ? '<span class="wfield-help' + (o.error ? ' bad' : '') + '">' + esc(o.help) + '</span>' : '') + '</label>';
  };
  W.pw = function (o) {
    o = Object.assign({ type: 'password' }, o);
    o.end = '<button class="wbtn ghost icon sm" data-toggle="check" data-weye="1" aria-label="Показать пароль">' + icon('eye', 18) + '</button>';
    return W.field(o);
  };
  W.search = function (placeholder, o) {
    o = o || {};
    return '<span class="winput wsearch"' + (o.style ? ' style="' + o.style + '"' : '') + '>' + icon('search', 18) + '<input type="search" placeholder="' + esc(placeholder) + '" value="' + esc(o.value || '') + '" data-wfilter="' + esc(o.target || '') + '" autocomplete="off" spellcheck="false" aria-label="' + esc(placeholder) + '"></span>';
  };
  W.filters = function (items, o) {
    o = o || {};
    return '<div class="wfilters"' + (o.group ? ' data-fgroup="' + esc(o.group) + '"' : '') + '>' + items.map(function (it) {
      return '<button class="wf' + (it.on ? ' is-on' : '') + '" data-toggle="radio" data-key="' + esc(it.key || '') + '">' + (it.dot ? '<i class="dot ' + it.dot + '"></i>' : '') + esc(it.label) +
        (it.count != null ? '<span class="cnt">' + esc(it.count) + '</span>' : '') + '</button>';
    }).join('') + '</div>';
  };
  W.table = function (cols, rows, o) {
    o = o || {};
    return '<div class="wtbl-wrap"' + (o.id ? ' data-table="' + esc(o.id) + '"' : '') + '><table class="wtbl' + (o.dense ? ' dense' : '') + '"><thead><tr>' + cols.map(function (c) { return '<th' + (c.cls ? ' class="' + c.cls + '"' : '') + (c.w ? ' style="width:' + c.w + '"' : '') + '>' + esc(c.label || '') + '</th>'; }).join('') + '</tr></thead><tbody>' +
      rows.map(function (r) {
        return '<tr class="' + (r.cls || '') + '" ' + act(r.act) + (r.key ? ' data-key="' + esc(r.key) + '"' : '') + (r.text ? ' data-text="' + esc(r.text) + '"' : '') + '>' +
          r.cells.map(function (c, i) { return '<td' + (cols[i] && cols[i].cls ? ' class="' + cols[i].cls + '"' : '') + '>' + c + '</td>'; }).join('') + '</tr>';
      }).join('') + '</tbody></table>' + (o.empty ? '<div class="wtbl-empty">' + o.empty + '</div>' : '') + '</div>';
  };
  W.kv = function (pairs, o) {
    return '<div class="wkv' + (o && o.cols ? ' cols' : '') + '">' + pairs.map(function (p) { return '<div class="wkv-r"><span>' + esc(p[0]) + '</span><span>' + (p[2] ? p[1] : esc(p[1])) + '</span></div>'; }).join('') + '</div>';
  };
  W.sec = function (o) {
    return '<section class="wsec' + (o.cls ? ' ' + o.cls : '') + '">' + (o.title ? '<div class="wsec-h"><div><h2>' + esc(o.title) + '</h2>' + (o.sub ? '<p>' + esc(o.sub) + '</p>' : '') + '</div>' + (o.right ? '<div class="wsec-r">' + o.right + '</div>' : '') + '</div>' : '') + (o.body || '') + '</section>';
  };
  W.panel = function (o) {
    var head = (o.title || o.right) ? '<div class="wpanel-h"><div>' + (o.title ? '<h3>' + esc(o.title) + '</h3>' : '') + (o.sub ? '<p>' + esc(o.sub) + '</p>' : '') + '</div>' + (o.right || '') + '</div>' : '';
    return '<section class="' + KV.cls('wpanel', o.cls, KV.isAct(o) && 'is-link') + '" ' + act(o) + '>' + head + (o.body || '') + '</section>';
  };
  W.kpis = function (items) {
    return '<div class="wkpis" style="--n:' + items.length + '">' + items.map(function (k) {
      return '<div class="' + KV.cls('wkpi', k.status, KV.isAct(k) && 'is-link') + '" ' + act(k) + '><div class="wkpi-l">' + (k.icon ? icon(k.icon, 16) : '') + '<span>' + esc(k.label) + '</span></div>' +
        '<div class="wkpi-v"><span class="wnum">' + esc(k.value) + '</span>' + (k.unit ? '<span class="wunit">' + esc(k.unit) + '</span>' : '') + '</div>' +
        (k.note ? '<div class="wkpi-n">' + (k.noteIcon ? icon(k.noteIcon, 14) : '') + '<span>' + esc(k.note) + '</span></div>' : '') + '</div>';
    }).join('') + '</div>';
  };
  W.drawer = function (o) {
    return '<aside class="wdrawer' + (o.wide ? ' wide' : '') + '" role="dialog" aria-label="' + esc(o.title) + '"><div class="wdrawer-h">' + (o.lead || '') + '<div class="wgrow">' + (o.kicker || '') + '<h2>' + esc(o.title) + '</h2>' + (o.sub ? '<p>' + esc(o.sub) + '</p>' : '') + (o.chips ? '<div class="wtags" style="margin-top:6px">' + o.chips + '</div>' : '') + '</div>' +
      W.ibtn('close', { kind: 'ghost', close: true, label: 'Закрыть' }) + '</div><div class="wdrawer-b">' + (o.body || '') + '</div>' + (o.foot ? '<div class="wdrawer-f">' + o.foot + '</div>' : '') + '</aside>';
  };
  W.modal = function (o) {
    return '<div class="wmodal-wrap' + (o.top ? ' top' : '') + '"><div class="' + KV.cls('wmodal', o.size, o.cls) + '" role="dialog" aria-label="' + esc(o.title || '') + '">' +
      (o.title ? '<div class="wmodal-h">' + (o.icon ? '<span class="wmodal-ic ' + (o.tone || '') + '">' + icon(o.icon, 22) + '</span>' : '') + '<div class="wgrow"><h2>' + esc(o.title) + '</h2>' + (o.text ? '<p>' + esc(o.text) + '</p>' : '') + '</div>' + (o.noClose ? '' : W.ibtn('close', { kind: 'ghost', close: true, label: 'Закрыть', size: 'sm' })) + '</div>' : '') +
      (o.body ? '<div class="wmodal-b">' + o.body + '</div>' : '') + (o.actions ? '<div class="wmodal-f">' + o.actions + '</div>' : '') + '</div></div>';
  };
  W.toast = function (o) {
    var k = o.kind || 'ok';
    var ic = o.icon || { bad: 'alert', ok: 'checkCircle', warn: 'alert', info: 'info' }[k];
    return '<div class="wtoast ' + k + '" role="status"><span class="wtoast-ic">' + icon(ic, 18) + '</span><div class="wtoast-t"><b>' + esc(o.title) + '</b>' + (o.text ? '<span>' + esc(o.text) + '</span>' : '') + '</div></div>';
  };
  W.empty = function (o) {
    return '<div class="wempty"><div class="wempty-ic ' + (o.tone || '') + '">' + icon(o.icon || 'search', 28) + '</div><h3>' + esc(o.title) + '</h3>' + (o.text ? '<p>' + esc(o.text) + '</p>' : '') + (o.action ? '<div class="wrow">' + o.action + '</div>' : '') + '</div>';
  };
  W.note = function (html, o) { o = o || {}; return '<div class="wnote ' + (o.tone || '') + '">' + icon(o.icon || 'info', 18) + '<div>' + html + '</div></div>'; };
  W.sw = function (on, o) { o = o || {}; return '<span class="wsw' + (on ? ' is-on' : '') + (o.locked ? ' is-locked' : '') + '" data-toggle="switch" role="switch" aria-checked="' + (on ? 'true' : 'false') + '"' + (o.label ? ' aria-label="' + esc(o.label) + '"' : '') + (o.attrs ? ' ' + o.attrs : '') + '></span>'; };
  W.check = function (on, o) { o = o || {}; return '<span class="wcheck' + (on ? ' is-on' : '') + (o.locked ? ' is-locked' : '') + '" data-toggle="chip" role="checkbox" aria-checked="' + (on ? 'true' : 'false') + '"' + (o.attrs ? ' ' + o.attrs : '') + '></span>'; };
  W.stepper = function (v, o) {
    o = o || {};
    return '<span class="wstep" data-step="' + esc(o.key || '') + '" data-min="' + (o.min || 0) + '" data-max="' + (o.max || 9999) + '" data-inc="' + (o.inc || 1) + '" data-orig="' + v + '">' +
      '<button data-toggle="tab-active" data-d="-1" aria-label="Меньше">' + icon('minus', 16) + '</button><output>' + KV.num(v) + '</output>' +
      '<button data-toggle="tab-active" data-d="1" aria-label="Больше">' + icon('plus', 16) + '</button>' + (o.suffix ? '<span class="wsuffix">' + esc(o.suffix) + '</span>' : '') + '</span>';
  };
  W.radios = function (items, o) {
    o = o || {};
    return '<div class="wradios' + (o.row ? ' row' : '') + '">' + items.map(function (it) {
      return '<button class="wradio' + (it.on ? ' is-on' : '') + '" data-toggle="radio"' + (it.key ? ' data-key="' + esc(it.key) + '"' : '') + '><span class="wradio-t"><b>' + esc(it.title) + '</b>' + (it.sub ? '<span>' + esc(it.sub) + '</span>' : '') + '</span>' + (it.right ? '<span class="wradio-r">' + esc(it.right) + '</span>' : '') + '</button>';
    }).join('') + '</div>';
  };
  W.bar = function (pct, status) { return '<div class="wbar ' + (status || '') + '"><i style="width:' + Math.max(0, Math.min(100, pct)) + '%"></i></div>'; };
  W.stripe = function (pct) { return '<div class="wstripe"><i style="width:' + Math.max(2, Math.min(100, pct)) + '%"></i></div>'; };
  W.meter = function (label, val, pct, status) { return '<div class="wmeter"><div class="wmeter-h"><span>' + esc(label) + '</span><b>' + esc(val) + '</b></div>' + W.bar(pct, status) + '</div>'; };
  W.tag = function (text, cls) { return '<span class="wtag' + (cls ? ' ' + cls : '') + '">' + esc(text) + '</span>'; };
  W.src = function (model) { return model ? '<span class="wtag model" title="Модельные данные">модель</span>' : '<span class="wtag">база заказчика</span>'; };
  W.level = function (lv) {
    var m = { bad: ['bad', 'Ошибка'], warn: ['warn', 'Внимание'], info: ['info', 'Сведения'], ok: ['ok', 'Успешно'] }[lv] || ['unk', lv];
    return '<span class="wlevel"><i class="dot ' + m[0] + '"></i>' + m[1] + '</span>';
  };
  W.li = function (o) {
    return '<div class="wli" ' + act(o) + '><span class="wli-ic ' + (o.tone || '') + '">' + icon(o.icon || 'info', 16) + '</span><span class="wli-t"><b>' + (o.titleHtml || esc(o.title)) + '</b>' + (o.text ? '<span>' + esc(o.text) + '</span>' : '') + '</span>' + (o.right != null ? '<span class="wli-r">' + o.right + '</span>' : '') + '</div>';
  };
  W.skel = function (w, hh, r) { return '<span class="wskel" style="width:' + w + ';height:' + hh + 'px' + (r ? ';border-radius:' + r + 'px' : '') + '"></span>'; };
  W.gauge = function (o) {
    var n = o.segs || 40, a0 = -210, a1 = 30, cx = 140, cy = 132, r1 = 104, r2 = 126;
    var filled = Math.round(n * Math.min(1, o.value / (o.max || 100)));
    var s = '';
    for (var i = 0; i < n; i++) {
      var a = (a0 + (a1 - a0) * (i + 0.5) / n) * Math.PI / 180;
      var x1 = cx + r1 * Math.cos(a), y1 = cy + r1 * Math.sin(a), x2 = cx + r2 * Math.cos(a), y2 = cy + r2 * Math.sin(a);
      var v = (i + 1) / n * (o.max || 100);
      var col = i < filled ? KV.levelColor(KV.level(v, o.warn, o.alarm, (o.max || 100) * 0.02)) : 'var(--w-line)';
      s += '<line x1="' + x1.toFixed(1) + '" y1="' + y1.toFixed(1) + '" x2="' + x2.toFixed(1) + '" y2="' + y2.toFixed(1) + '" stroke="' + col + '" stroke-width="5" stroke-linecap="round"/>';
    }
    return '<div class="wgauge"><svg viewBox="0 0 280 200" aria-hidden="true">' + s + '</svg><div class="wgauge-c"><div class="wkpi-v"><span class="wnum l">' + esc(o.text != null ? o.text : KV.num(o.value)) + '</span>' + (o.unit ? '<span class="wunit">' + esc(o.unit) + '</span>' : '') + '</div><span class="wlabel">' + esc(o.label || '') + '</span></div></div>';
  };
  W.dial = function (o) {
    var sweep = o.sweep || 270, a0 = 90 + (360 - sweep) / 2, cx = 60, cy = 60, r = 46, s = '';
    for (var i = 0; i <= 10; i++) {
      var a = (a0 + sweep * i / 10) * Math.PI / 180, big = i % 5 === 0;
      s += '<line x1="' + (cx + (r - (big ? 10 : 6)) * Math.cos(a)).toFixed(1) + '" y1="' + (cy + (r - (big ? 10 : 6)) * Math.sin(a)).toFixed(1) + '" x2="' + (cx + r * Math.cos(a)).toFixed(1) + '" y2="' + (cy + r * Math.sin(a)).toFixed(1) + '" stroke="var(--text-2)" stroke-width="' + (big ? 2 : 1.2) + '" stroke-linecap="round"/>';
    }
    var av = (a0 + sweep * (o.value - o.min) / (o.max - o.min)) * Math.PI / 180;
    s += '<line x1="60" y1="60" x2="' + (cx + 34 * Math.cos(av)).toFixed(1) + '" y2="' + (cy + 34 * Math.sin(av)).toFixed(1) + '" stroke="var(--bad)" stroke-width="2.4" stroke-linecap="round"/><circle cx="60" cy="60" r="4.5" fill="var(--text)"/>';
    return '<svg class="wgauge-mini" viewBox="0 0 120 120" aria-hidden="true"><circle cx="60" cy="60" r="56" fill="none" stroke="var(--w-line-2)" stroke-width="1.5"/>' + s + '</svg>';
  };
  function tipShift(f, yf) { return 'translate(' + (f > 0.82 ? '-100%' : f < 0.18 ? '0%' : '-50%') + ', ' + (yf < 0.45 ? '14px' : 'calc(-100% - 14px)') + ')'; }
  W.chart = function (o) {
    var H = o.height || 220, min = o.min, max = o.max, n = o.values.length;
    var Y = function (v) { return 6 + (1 - (v - min) / (max - min)) * (H - 12); };
    var grid = (o.grid || []).map(function (g) { return '<span style="top:' + Y(g).toFixed(1) + 'px"><i>' + esc(KV.num(g, 0)) + '</i></span>'; }).join('');
    var ti = o.tip == null ? n - 1 : o.tip, tv = o.values[ti], tx = ti / (n - 1) * 100;
    var col = KV.levelColor(KV.level(tv, o.warn, o.alarm, (max - min) * 0.035));
    var tipTxt = o.tipText ? o.tipText(ti) : [KV.num(tv, o.digits || 0) + ' ' + (o.unit || ''), o.times ? o.times[ti] : ''];
    return '<div class="wchart" data-wchart="1">' +
      '<div class="wchart-plot" style="height:' + H + 'px"><div class="wchart-grid" style="height:' + H + 'px">' + grid + '</div>' +
      KV.areaChart({ values: o.values, warn: o.warn, alarm: o.alarm, min: min, max: max, height: H, dot: false, legend: false, stripes: true }) +
      '<span class="wtip-line" style="left:calc(44px + (100% - 44px) * ' + (tx / 100).toFixed(4) + ');height:' + H + 'px"></span>' +
      '<span class="wtip-dot" style="left:calc(44px + (100% - 44px) * ' + (tx / 100).toFixed(4) + ');top:' + Y(tv).toFixed(1) + 'px;border-color:' + col + '"></span>' +
      '<span class="wtip" style="left:calc(44px + (100% - 44px) * ' + (tx / 100).toFixed(4) + ');top:' + Y(tv).toFixed(1) + 'px;transform:' + tipShift(ti / (n - 1), Y(tv) / H) + '"><b>' + esc(tipTxt[0]) + '</b><span>' + esc(tipTxt[1]) + '</span></span>' +
      '<span class="wchart-hit" style="height:' + H + 'px" aria-hidden="true"></span></div>' +
      (o.axis ? '<div class="chart-axis">' + o.axis.map(function (l) { return '<span>' + esc(l) + '</span>'; }).join('') + '</div>' : '') +
      (o.legend ? '<div class="chart-legend">' + o.legend.map(function (it) { return '<span><i class="dot" style="background:' + it[0] + '"></i>' + esc(it[1]) + '</span>'; }).join('') + '</div>' : '') + '</div>';
  };
  W.chartAfter = function (root, o) {
    var box = root.querySelector('[data-wchart]');
    if (!box) return;
    var hit = box.querySelector('.wchart-hit'), tip = box.querySelector('.wtip'), line = box.querySelector('.wtip-line'), dot = box.querySelector('.wtip-dot');
    var H = o.height || 220, n = o.values.length;
    var Y = function (v) { return 6 + (1 - (v - o.min) / (o.max - o.min)) * (H - 12); };
    var place = function (i) {
      var x = 'calc(44px + (100% - 44px) * ' + (i / (n - 1)).toFixed(4) + ')', v = o.values[i];
      var t = o.tipText ? o.tipText(i) : [KV.num(v, o.digits || 0) + ' ' + (o.unit || ''), o.times ? o.times[i] : ''];
      line.style.left = x; dot.style.left = x; tip.style.left = x; tip.style.transform = tipShift(i / (n - 1), Y(v) / H);
      dot.style.top = Y(v).toFixed(1) + 'px'; tip.style.top = Y(v).toFixed(1) + 'px';
      dot.style.borderColor = KV.levelColor(KV.level(v, o.warn, o.alarm, (o.max - o.min) * 0.035));
      tip.querySelector('b').textContent = t[0]; tip.querySelector('span').textContent = t[1];
      KV.typo(tip);
    };
    hit.addEventListener('mousemove', function (e) {
      var r = hit.getBoundingClientRect();
      var i = Math.round(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * (n - 1));
      place(i);
    });
    hit.addEventListener('mouseleave', function () { place(o.tip == null ? n - 1 : o.tip); });
  };
  W.bindFilter = function (root, o) {
    var scope = root.querySelector(o.scope) || root;
    var input = root.querySelector(o.input || '[data-wfilter]');
    var groups = slice(root.querySelectorAll('.wfilters[data-fgroup]'));
    var empty = scope.querySelector('.wtbl-empty') || root.querySelector(o.empty || '.wtbl-empty');
    var fold = function (s) { return String(s || '').toLowerCase().replace(/ё/g, 'е'); };
    var apply = function () {
      var q = input ? fold(input.value).split(/\s+/).filter(Boolean) : [];
      var keys = groups.map(function (g) { var on = g.querySelector('.wf.is-on'); return on ? on.getAttribute('data-key') : ''; });
      var shown = 0;
      slice(scope.querySelectorAll(o.rows || 'tbody tr')).forEach(function (r) {
        var rk = (r.getAttribute('data-key') || '').split(' ');
        var txt = fold(r.getAttribute('data-text') || r.textContent);
        var ok = keys.every(function (k) { return !k || rk.indexOf(k) >= 0; }) && q.every(function (w) { return txt.indexOf(w) >= 0; });
        r.classList.toggle('is-hidden', !ok);
        if (ok) shown++;
      });
      if (empty) empty.classList.toggle('is-on', !shown);
      var tbl = scope.querySelector('table');
      if (tbl) tbl.style.display = shown ? '' : 'none';
      if (o.onChange) o.onChange(shown);
    };
    if (input) input.addEventListener('input', apply);
    groups.forEach(function (g) { g.addEventListener('click', function (e) { if (e.target.closest('.wf')) setTimeout(apply, 0); }); });
    apply();
    return apply;
  };
  W.PERSON = { admin: D.people.admin, sec: D.people.sec, master: D.people.master };
  W.NAV = {
    admin: [
      { label: 'Мониторинг', items: [
        { key: 'overview', icon: 'grid', label: 'Обзор системы', go: 'w-adm-overview' },
        { key: 'telemetry', icon: 'activity', label: 'Телеметрия и сценарии', go: 'w-adm-telemetry' },
        { key: 'sources', icon: 'plug', label: 'Источники данных', go: 'w-adm-sources', tone: 'warn', hint: 'Шлюз вибродатчиков: задержка 2,4 с' }] },
      { label: 'Ресурсы', items: [
        { key: 'equipment', icon: 'box', label: 'Оборудование', go: 'w-adm-equipment' },
        { key: 'models', icon: 'cpu', label: 'Распознавание', go: 'w-adm-models' }] },
      { label: 'Обслуживание', items: [
        { key: 'log', icon: 'archive', label: 'Журнал и резерв', go: 'w-adm-log' }] }
    ],
    sec: [
      { label: 'Доступ', items: [
        { key: 'users', icon: 'users', label: 'Пользователи', go: 'w-sec-users' },
        { key: 'roles', icon: 'key', label: 'Роли и права', go: 'w-sec-roles' }] },
      { label: 'Контроль', items: [
        { key: 'log', icon: 'list', label: 'Журнал безопасности', go: 'w-sec-log', tone: 'warn', hint: '3 попытки входа заблокированной записи' },
        { key: 'policy', icon: 'shield', label: 'Политика', go: 'w-sec-policy' }] }
    ],
    master: [
      { label: 'Смена', items: [
        { key: 'summary', icon: 'clipboard', label: 'Сводка смены', go: 'w-m-summary' }] }
    ]
  };
  W.PROFILE = { admin: 'w-adm-profile', sec: 'w-sec-profile', master: 'w-m-profile' };
  W.ROLE_LABEL = { admin: 'Админ', sec: 'Админ ИБ', master: 'Мастер' };
  function sideCard(role, o) {
    if (o.card === false) return '';
    if (role === 'admin') return '<div class="wnote-card"><b><i class="dot info"></i>Доступно обновление 1.5.0</b><p>' + esc(D.server.update.notes) + ' · ' + esc(D.server.update.size) + '</p>' + W.btn('Подробнее', { size: 'sm', kind: 'secondary', go: o.id + '-update' }) + '</div>';
    if (role === 'sec') return '<div class="wnote-card"><b><i class="dot warn"></i>Временный пароль</b><p>Павел Ершов ещё не входил. Пароль действует до 15.11, 09:08.</p>' + W.btn('Открыть запись', { size: 'sm', kind: 'secondary', go: 'w-sec-user-u-110' }) + '</div>';
    return '<div class="wnote-card"><b><i class="dot info"></i>Только просмотр</b><p>Подтверждение находок и план ТО - в приложении на телефоне.</p></div>';
  }
  W.side = function (role, o) {
    var p = W.PERSON[role];
    var nav = (W.NAV[role] || []).map(function (g) {
      return '<div class="wnav-label">' + esc(g.label) + '</div>' + g.items.map(function (it) {
        var on = it.key === o.nav;
        return '<button class="wnav-item' + (on ? ' is-on' : '') + '" data-nav="' + it.key + '" ' + (on ? 'data-toggle="tab-active"' : act({ go: it.go, nav: 'tab' })) + '>' + icon(it.icon, 18) + '<span>' + esc(it.label) + '</span>' +
          (it.tone ? '<i class="wnav-dot" title="' + esc(it.hint || '') + '"></i>' : '') + '</button>';
      }).join('');
    }).join('');
    var onProfile = o.nav === 'profile';
    return '<aside class="wside"><div class="wlogo">' + KV.logo('blue', 24).replace('class="logo-img"', 'class="logo-img wlogo-l"') + KV.logo('white', 24).replace('class="logo-img"', 'class="logo-img wlogo-d"') + '<span class="wlogo-sub">КСТ Визор · веб-панель</span></div>' +
      '<button class="wws" ' + act({ toast: 'Насосная станция № 2|Панель подключена к серверу КСТ-СРВ-02 (10.20.4.15). Другие станции подключаются отдельно.', toastKind: 'info', toastIcon: 'server' }) + '><span class="wws-t"><b>Насосная станция № 2</b><span>КСТ-СРВ-02 · 10.20.4.15</span></span>' + icon('chevronDown', 16) + '</button>' +
      '<nav class="wnav">' + nav + '</nav><div class="wside-fill"></div>' + sideCard(role, o) +
      '<button class="wuser" ' + (onProfile ? 'data-toggle="tab-active"' : act({ go: W.PROFILE[role], nav: 'tab' })) + ' aria-label="Профиль">' + KV.avatar(p.name) + '<span class="wuser-t"><b>' + esc(p.name) + '</b><span>' + esc(W.ROLE_LABEL[role]) + ' · профиль</span></span>' + icon('chevronRight', 16) + '</button></aside>';
  };
  W.topRight = function (role, o) {
    return (o.actions || '') +
      '<button class="wsearch-btn" data-cmdk="1" ' + act({ go: o.id + '-cmdk' }) + ' aria-label="Быстрый поиск">' + icon('search', 18) + '<span>Поиск</span><span class="wkbd">⌘K</span></button>' +
      W.btn('', { kind: 'secondary', icon: 'bell', go: o.id + '-notif', label: 'Уведомления', badge: true });
  };
  W.shell = function (o) {
    return W.side(o.role, o) + '<section class="wmain">' +
      '<header class="wtop"><div class="wtop-t"><h1>' + esc(o.title) + '</h1>' + (o.sub ? '<p>' + esc(o.sub) + '</p>' : '') + '</div><div class="wtop-r">' + W.topRight(o.role, o) + '</div></header>' +
      (o.banner || '') + '<div class="wmain-in">' + (o.body || '') + '</div></section>';
  };
  W.today = 'Суббота, 14 ноября 2026 · 09:41';
  W.CMDK = {};
  W.cmdk = function (role) {
    var groups = (W.CMDK[role] || []).map(function (g) {
      return '<div class="wpal-g">' + esc(g.group) + '</div>' + g.items.map(function (it) {
        return '<button class="wpal-i" ' + act({ go: it.go, nav: it.nav }) + ' data-text="' + esc((it.label + ' ' + (it.sub || '') + ' ' + (it.keys || '')).toLowerCase()) + '">' + icon(it.icon || 'arrowRight', 18) + '<span>' + esc(it.label) + '</span>' + (it.sub ? '<small>' + esc(it.sub) + '</small>' : '') + '</button>';
      }).join('');
    }).join('');
    return W.modal({ top: true, size: 'm', cls: 'wpal', body:
      '<div class="wpal-in">' + icon('search', 20) + '<input type="text" placeholder="Раздел, агрегат, сотрудник или действие" data-autofocus="1" aria-label="Быстрый поиск" autocomplete="off" spellcheck="false"><span class="wkbd">Esc</span></div>' +
      '<div class="wpal-list">' + groups + '<div class="wpal-none">Ничего не найдено. Попробуйте код агрегата, фамилию или название раздела.</div></div>' +
      '<div class="wpal-foot"><span><span class="wkbd">↑</span><span class="wkbd">↓</span>выбор</span><span><span class="wkbd">Enter</span>открыть</span><span><span class="wkbd">Esc</span>закрыть</span></div>' });
  };
  W.cmdkAfter = function (root) {
    var input = root.querySelector('.wpal-in input');
    var items = slice(root.querySelectorAll('.wpal-i'));
    var none = root.querySelector('.wpal-none');
    var sel = 0;
    var vis = function () { return items.filter(function (i) { return i.style.display !== 'none'; }); };
    var mark = function () { var v = vis(); items.forEach(function (i) { i.classList.remove('is-sel'); }); if (v[sel]) v[sel].classList.add('is-sel'); };
    var apply = function () {
      var q = (input.value || '').toLowerCase().replace(/ё/g, 'е').trim();
      items.forEach(function (i) { i.style.display = !q || i.getAttribute('data-text').replace(/ё/g, 'е').indexOf(q) >= 0 ? '' : 'none'; });
      slice(root.querySelectorAll('.wpal-g')).forEach(function (g) {
        var n = g.nextElementSibling, any = false;
        while (n && n.classList.contains('wpal-i')) { if (n.style.display !== 'none') any = true; n = n.nextElementSibling; }
        g.style.display = any ? '' : 'none';
      });
      none.classList.toggle('is-on', !vis().length);
      sel = 0; mark();
    };
    input.addEventListener('input', apply);
    input.addEventListener('keydown', function (e) {
      var v = vis();
      if (e.key === 'ArrowDown') { e.preventDefault(); sel = Math.min(v.length - 1, sel + 1); mark(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(0, sel - 1); mark(); }
      else if (e.key === 'Enter' && v[sel]) { e.preventDefault(); v[sel].click(); }
    });
    mark();
  };
  W.NOTIF = {};
  W.notif = function (role) {
    var list = W.NOTIF[role] || [];
    return W.drawer({ title: 'Уведомления', sub: list.length + ' за сутки · ' + W.ROLE_LABEL[role], body:
      '<div class="wlist pad">' + list.map(function (n) { return W.li({ tone: n.tone, icon: n.icon, title: n.title, text: n.text, right: esc(n.time), go: n.go }); }).join('') + '</div>',
      foot: '<span class="wgrow">Важные события дублируются на телефон дежурного</span>' + W.btn('Отметить прочитанными', { kind: 'secondary', size: 'sm', toast: 'Уведомления прочитаны|Счётчик сброшен на этом устройстве', toastKind: 'ok', closeAfter: true }) });
  };
  W.updateModal = function (pageId) {
    var u = D.server.update;
    return W.modal({ icon: 'download', title: 'Обновление сервера ' + u.available, text: 'Установлена версия ' + D.server.version + '. Размер пакета ' + u.size + '.', size: 'm', body:
      W.kv([['Что нового', u.notes], ['Перед установкой', 'резервная копия базы и моделей'], ['Простой', 'около 2 мин, телефоны переподключатся сами'], ['Откат', 'к версии ' + D.server.version + ' из резервной копии']]) +
      W.note('Во время установки идущие осмотры сохраняются на телефонах и отправляются после перезапуска сервера.', { icon: 'info' }),
      actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Ночью в 03:30', { kind: 'secondary', go: pageId + '-update-later' }) + W.btn('Установить сейчас', { kind: 'primary', icon: 'download', go: pageId + '-update-run', wait: true }) });
  };
})();
