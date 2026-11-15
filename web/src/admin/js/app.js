/**
 * Основа веб-панели «КСТ Визор»: сеанс и обращения к API сервера, оболочка с боковым меню по ролям,
 * панели, окна и уведомления, переключатели и маршруты страниц.
 */
(function () {
  'use strict';
  var KV = window.KV, W = KV.w, esc = KV.esc, icon = KV.icon;
  var A = window.WA = {};
  var root = document.getElementById('app');
  A.root = root;
  A.pages = {};
  A.user = null;

  /** Хранилище токенов сеанса в sessionStorage: доступ и обновление. */
  var store = {
    get: function (k) { try { return sessionStorage.getItem('kv_' + k); } catch (e) { return null; } },
    set: function (k, v) { try { if (v == null) sessionStorage.removeItem('kv_' + k); else sessionStorage.setItem('kv_' + k, v); } catch (e) { return; } }
  };
  A.store = store;

  /** Ошибка ответа сервера с кодом и русским объяснением. */
  function ApiError(status, detail, headers) { this.status = status; this.detail = detail; this.headers = headers; }
  A.ApiError = ApiError;

  function detailOf(body, status) {
    if (body && typeof body.detail === 'string') return body.detail;
    if (body && Array.isArray(body.detail)) return body.detail.map(function (d) { return d.msg; }).join('; ');
    if (status === 0) return 'Нет связи с сервером';
    return 'Ошибка сервера (' + status + ')';
  }

  /** Последние ответы GET с меткой содержимого: при повторном опросе сервер отвечает 304 без тела. */
  var tagged = {};
  function parse(text) { try { return text ? JSON.parse(text) : null; } catch (e) { return null; } }
  function raw(method, path, body, token) {
    var h = { 'Accept': 'application/json' };
    if (body !== undefined) h['Content-Type'] = 'application/json';
    if (token) h.Authorization = 'Bearer ' + token;
    var kept = method === 'GET' ? tagged[path] : null;
    if (method === 'GET') h['If-None-Match'] = kept && kept.token === token ? kept.tag : '"0"';
    return fetch(path, { method: method, headers: h, body: body !== undefined ? JSON.stringify(body) : undefined, cache: 'no-store' })
      .then(function (r) {
        if (r.status === 204) return { status: 204, body: null, headers: r.headers };
        if (r.status === 304 && kept) return { status: 200, body: parse(kept.text), headers: r.headers };
        return r.text().catch(function () { return ''; }).then(function (text) {
          var tag = r.headers.get('ETag');
          if (method === 'GET' && r.status === 200 && tag) tagged[path] = { tag: tag, text: text, token: token };
          return { status: r.status, body: parse(text), headers: r.headers };
        });
      }, function () { return { status: 0, body: null }; });
  }

  var refreshing = null;
  /** Обновляет пару токенов по токену обновления; один запрос на все параллельные обращения. */
  function refresh() {
    if (refreshing) return refreshing;
    var rt = store.get('refresh');
    if (!rt) return Promise.resolve(false);
    refreshing = raw('POST', '/auth/refresh', { refresh_token: rt }).then(function (r) {
      refreshing = null;
      if (r.status === 200) { A.saveTokens(r.body); return true; }
      return false;
    });
    return refreshing;
  }
  A.saveTokens = function (t) { store.set('access', t.access_token); store.set('refresh', t.refresh_token); };
  A.clearTokens = function () { store.set('access', null); store.set('refresh', null); tagged = {}; };

  /** Обращение к API: токен доступа, повтор после обновления при ответе 401, ошибка ApiError при отказе. */
  A.api = function (method, path, body) {
    return raw(method, path, body, store.get('access')).then(function (r) {
      if (r.status === 401 && store.get('refresh')) {
        return refresh().then(function (ok) {
          if (!ok) { A.sessionLost(); throw new ApiError(401, 'Сеанс завершён - войдите заново'); }
          return raw(method, path, body, store.get('access'));
        });
      }
      return r;
    }).then(function (r) {
      if (r.status >= 200 && r.status < 300) return r.body;
      if (r.status === 401) A.sessionLost();
      throw new ApiError(r.status, detailOf(r.body, r.status), r.headers);
    });
  };
  A.get = function (p) { return A.api('GET', p); };
  A.post = function (p, b) { return A.api('POST', p, b === undefined ? {} : b); };
  A.patch = function (p, b) { return A.api('PATCH', p, b); };
  A.del = function (p) { return A.api('DELETE', p); };
  A.raw = raw;

  A.sessionLost = function () {
    if (!A.user) return;
    A.user = null; A.clearTokens();
    A.go('login');
    A.toast('Сеанс завершён', 'Войдите заново: срок сеанса истёк или сеанс закрыт администратором ИБ', 'warn', 'lock');
  };

  /** Права и роль: какие разделы панели доступны вошедшему сотруднику. */
  A.can = function (perm) { return !!(A.user && A.user.permissions.indexOf(perm) >= 0); };
  A.isSec = function () { return A.can('users.manage') || A.can('roles.manage') || A.can('security.log') || A.can('security.policy'); };
  A.isAdmin = function () { return A.can('system.manage'); };
  A.isMaster = function () { return A.can('findings.view') && (A.can('inspect.supervise') || A.can('findings.confirm') || A.can('reports.all')); };
  A.hasWeb = function () { return A.isSec() || A.isAdmin() || A.isMaster(); };
  A.roleLabel = function () {
    if (!A.user) return '';
    if (A.user.role === 'security_admin') return 'Админ ИБ';
    if (A.user.role === 'admin') return 'Админ';
    var t = A.user.role_title || A.user.role;
    return t.charAt(0).toUpperCase() + t.slice(1);
  };

  /** Форматирование: время, даты, размеры, длительности. */
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  A.pad = pad;
  A.dt = function (iso, o) {
    if (!iso) return '—';
    var d = new Date(iso);
    if (isNaN(d)) return String(iso);
    var date = pad(d.getDate()) + '.' + pad(d.getMonth() + 1) + (o && o.year === false ? '' : '.' + d.getFullYear());
    var time = pad(d.getHours()) + ':' + pad(d.getMinutes()) + (o && o.sec ? ':' + pad(d.getSeconds()) : '');
    if (o && o.date) return date;
    if (o && o.time) return time;
    return date + ', ' + time;
  };
  A.bytes = function (b) {
    if (b == null) return '—';
    if (b < 1024) return b + ' Б';
    var u = ['КБ', 'МБ', 'ГБ', 'ТБ'], i = -1;
    do { b /= 1024; i++; } while (b >= 1024 && i < u.length - 1);
    return KV.num(b, b < 10 ? 1 : 0) + ' ' + u[i];
  };
  A.dur = function (s) {
    if (s == null) return '—';
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (d) return d + ' сут ' + h + ' ч';
    if (h) return h + ' ч ' + m + ' мин';
    return m ? m + ' мин' : (s % 60) + ' с';
  };
  A.isoLocal = function (d) {
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + 'T' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  };

  /** Тема оформления: светлая или тёмная, выбор хранится в браузере. */
  A.theme = function (v) {
    if (v) { try { localStorage.setItem('kv_theme', v); } catch (e) { v = v || 'light'; } }
    var t = v;
    if (!t) { try { t = localStorage.getItem('kv_theme'); } catch (e2) { t = null; } }
    if (!t) t = (window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
    root.setAttribute('data-theme', t);
    document.documentElement.style.colorScheme = t;
    var b = root.querySelector('[data-theme-toggle]');
    if (b) b.innerHTML = icon(t === 'dark' ? 'sun' : 'moon', 18);
    return t;
  };

  /** Окна поверх страницы: боковая панель (drawer), диалог (modal) и уведомление (toast). */
  var stack = [];
  A.still = function () { return !!(window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches); };
  function anim(el, frames, ms) { if (el && el.animate && !A.still()) return el.animate(frames, { duration: ms, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)', fill: 'both' }); return null; }
  A.open = function (html, o) {
    o = o || {};
    var ovl = document.createElement('div');
    ovl.className = 'ovl wovl';
    ovl.innerHTML = html;
    var kind = ovl.querySelector('.wdrawer') ? 'drawer' : 'modal';
    ovl.classList.add('is-' + kind);
    ovl.dataset.kind = kind;
    var scrim = document.createElement('div');
    scrim.className = 'ovl-scrim wscrim';
    scrim.setAttribute('data-close', '1');
    ovl.insertBefore(scrim, ovl.firstChild);
    if (o.replace) {
      var prev = o.replace === true ? stack[stack.length - 1] : o.replace;
      if (prev && prev.parentNode) { stack.splice(stack.indexOf(prev), 1); prev.parentNode.removeChild(prev); }
    }
    root.appendChild(ovl);
    stack.push(ovl);
    ovl.__onClose = o.onClose;
    W.typo(ovl);
    KV.layoutSegs && KV.layoutSegs(ovl);
    if (!o.replace) {
      anim(scrim, [{ opacity: 0 }, { opacity: 1 }], 200);
      var box = ovl.querySelector('.wdrawer, .wmodal');
      anim(box, kind === 'drawer' ? [{ transform: 'translateX(104%)' }, { transform: 'none' }] : [{ opacity: 0, transform: 'scale(.97) translateY(6px)' }, { opacity: 1, transform: 'none' }], kind === 'drawer' ? 320 : 220);
    }
    var f = ovl.querySelector('[data-autofocus]');
    if (f) setTimeout(function () { try { f.focus(); } catch (e) { return; } }, 60);
    return ovl;
  };
  A.close = function (ovl) {
    ovl = ovl || stack[stack.length - 1];
    if (!ovl) return;
    var i = stack.indexOf(ovl);
    if (i >= 0) stack.splice(i, 1);
    var box = ovl.querySelector('.wdrawer, .wmodal'), scrim = ovl.querySelector('.wscrim');
    var a = anim(box, ovl.dataset.kind === 'drawer' ? [{ transform: 'none' }, { transform: 'translateX(104%)' }] : [{ opacity: 1 }, { opacity: 0, transform: 'scale(.98)' }], 180);
    anim(scrim, [{ opacity: 1 }, { opacity: 0 }], 180);
    var done = function () { if (ovl.parentNode) ovl.parentNode.removeChild(ovl); };
    if (a) a.onfinish = done; else done();
    if (ovl.__onClose) ovl.__onClose();
  };
  A.closeAll = function () { while (stack.length) { var o = stack.pop(); if (o.parentNode) o.parentNode.removeChild(o); } };
  A.top = function () { return stack[stack.length - 1]; };

  A.toast = function (title, text, kind, ic) {
    Array.prototype.forEach.call(root.querySelectorAll(':scope > .wovl.is-toast'), function (n) { n.parentNode.removeChild(n); });
    var ovl = document.createElement('div');
    ovl.className = 'ovl wovl is-toast';
    ovl.innerHTML = W.toast({ kind: kind || 'ok', title: title, text: text, icon: ic });
    W.typo(ovl);
    root.appendChild(ovl);
    var box = ovl.querySelector('.wtoast');
    anim(box, [{ opacity: 0, transform: 'translateY(-10px)' }, { opacity: 1, transform: 'none' }], 240);
    setTimeout(function () {
      var a = anim(box, [{ opacity: 1 }, { opacity: 0, transform: 'translateY(-6px)' }], 220);
      var rm = function () { if (ovl.parentNode) ovl.parentNode.removeChild(ovl); };
      if (a) a.onfinish = rm; else rm();
    }, kind === 'bad' ? 5200 : 3600);
  };
  A.fail = function (err, title) {
    var text = err && err.detail ? err.detail : String(err && err.message || err);
    A.toast(title || 'Не удалось выполнить', text, 'bad');
  };

  /** Кнопка с индикатором ожидания на время запроса. */
  A.busy = function (btn, promise) {
    if (btn) { btn.classList.add('is-loading'); btn.disabled = true; }
    var end = function () { if (btn) { btn.classList.remove('is-loading'); btn.disabled = false; } };
    return promise.then(function (v) { end(); return v; }, function (e) { end(); throw e; });
  };

  /** Копирование в буфер обмена с запасным путём для адреса без HTTPS. */
  A.copy = function (text) {
    var fallback = function () {
      var t = document.createElement('textarea');
      t.value = text; t.style.position = 'fixed'; t.style.opacity = '0';
      document.body.appendChild(t); t.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(t);
      return ok;
    };
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text).then(function () { return true; }, fallback);
    return Promise.resolve(fallback());
  };

  /** Переключатели оформления: выключатель, флажок, выбор одного из чипов, радиокнопок и сегментов. */
  root.addEventListener('click', function (e) {
    var t = e.target;
    var close = t.closest('[data-close]');
    if (close) { var ov = close.closest('.wovl'); if (ov) { A.close(ov); return; } }
    var sw = t.closest('.wsw');
    if (sw && !sw.classList.contains('is-locked')) { sw.classList.toggle('is-on'); sw.setAttribute('aria-checked', sw.classList.contains('is-on') ? 'true' : 'false'); }
    var ch = t.closest('.wcheck');
    if (ch && !ch.classList.contains('is-locked')) { ch.classList.toggle('is-on'); ch.setAttribute('aria-checked', ch.classList.contains('is-on') ? 'true' : 'false'); }
    var f = t.closest('.wfilters .wf');
    if (f) { Array.prototype.forEach.call(f.parentNode.querySelectorAll('.wf'), function (x) { x.classList.toggle('is-on', x === f); }); }
    var r = t.closest('.wradios .wradio');
    if (r) { Array.prototype.forEach.call(r.parentNode.querySelectorAll('.wradio'), function (x) { x.classList.toggle('is-on', x === r); }); }
    var s = t.closest('[data-seg] .seg-item');
    if (s) { Array.prototype.forEach.call(s.parentNode.querySelectorAll('.seg-item'), function (x) { x.classList.toggle('is-on', x === s); }); KV.layoutSegs(s.parentNode.parentNode, true); }
    var nav = t.closest('[data-route]');
    if (nav) { e.preventDefault(); A.go(nav.getAttribute('data-route')); }
    if (t.closest('[data-theme-toggle]')) A.theme(root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark');
    if (t.closest('[data-nav-toggle]')) A.nav(!root.classList.contains('nav-open'));
    else if (t.closest('[data-nav-close]')) A.nav(false);
  });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && stack.length) { e.preventDefault(); A.close(); }
    else if (e.key === 'Escape' && root.classList.contains('nav-open')) A.nav(false);
  });

  KV.layoutSegs = function (scope, animate) {
    Array.prototype.forEach.call((scope || root).querySelectorAll('[data-seg]'), function (seg) {
      var ind = seg.querySelector('.seg-ind'), on = seg.querySelector('.seg-item.is-on');
      if (!ind) return;
      if (!on) { ind.style.opacity = '0'; return; }
      if (!animate) ind.style.transition = 'none';
      ind.style.opacity = '1';
      ind.style.width = on.offsetWidth + 'px';
      ind.style.transform = 'translateX(' + (on.offsetLeft - 3) + 'px)';
      if (!animate) { void ind.offsetWidth; ind.style.transition = ''; }
    });
  };

  /** Боковое меню по правам сотрудника: Админ ИБ, Админ, Мастер. */
  A.navGroups = function () {
    var g = [];
    if (A.isAdmin()) {
      g.push({ label: 'Мониторинг', items: [{ key: 'overview', icon: 'grid', label: 'Обзор системы' }, { key: 'telemetry', icon: 'activity', label: 'Телеметрия и сценарии' }] });
      g.push({ label: 'Ресурсы', items: [{ key: 'equipment', icon: 'box', label: 'Оборудование' }, { key: 'models', icon: 'cpu', label: 'Распознавание' }] });
      g.push({ label: 'Обслуживание', items: [{ key: 'log', icon: 'archive', label: 'Журнал и резерв' }] });
    }
    if (A.isSec()) {
      var acc = [];
      if (A.can('users.manage')) acc.push({ key: 'users', icon: 'users', label: 'Пользователи' });
      if (A.can('roles.manage') || A.can('users.manage')) acc.push({ key: 'roles', icon: 'key', label: 'Роли и права' });
      if (acc.length) g.push({ label: 'Доступ', items: acc });
      var ctl = [];
      if (A.can('security.log')) ctl.push({ key: 'seclog', icon: 'list', label: 'Журнал безопасности' });
      if (A.can('security.policy')) ctl.push({ key: 'policy', icon: 'shield', label: 'Политика' });
      if (ctl.length) g.push({ label: 'Контроль', items: ctl });
    }
    if (A.isMaster() && !A.isAdmin() && !A.isSec()) g.push({ label: 'Смена', items: [{ key: 'summary', icon: 'clipboard', label: 'Сводка смены' }] });
    return g;
  };
  A.home = function () {
    var g = A.navGroups();
    return g.length ? g[0].items[0].key : 'noaccess';
  };

  A.serverLine = function () { return location.host; };
  /** Боковое меню на узком экране: выдвигается поверх страницы и закрывается затемнением или выбором раздела. */
  A.nav = function (open) {
    root.classList.toggle('nav-open', !!open);
    var b = root.querySelector('[data-nav-toggle]');
    if (b) b.setAttribute('aria-expanded', open ? 'true' : 'false');
  };

  function side(navKey) {
    var nav = A.navGroups().map(function (g) {
      return '<div class="wnav-label">' + esc(g.label) + '</div>' + g.items.map(function (it) {
        return '<button class="wnav-item' + (it.key === navKey ? ' is-on' : '') + '" data-nav="' + it.key + '" data-route="' + it.key + '">' + icon(it.icon, 18) + '<span>' + esc(it.label) + '</span></button>';
      }).join('');
    }).join('');
    var card = A.isMaster() && !A.isAdmin() && !A.isSec()
      ? '<div class="wnote-card"><b><i class="dot info"></i>Только просмотр</b><p>Подтверждение находок и план ТО - в приложении на телефоне.</p></div>'
      : '<div class="wnote-card"><b><i class="dot ok"></i>Сервер на связи</b><p data-side-note="1">Панель подключена к серверу ' + esc(A.serverLine()) + '. Данные загружаются из API в реальном времени.</p></div>';
    return '<aside class="wside"><div class="wlogo">' + KV.logo('blue', 24).replace('class="logo-img"', 'class="logo-img wlogo-l"') + KV.logo('white', 24).replace('class="logo-img"', 'class="logo-img wlogo-d"') + '<span class="wlogo-sub">КСТ Визор · веб-панель</span></div>' +
      '<div class="wws"><span class="wws-t"><b>Насосная станция № 2</b><span>' + esc(A.serverLine()) + '</span></span>' + icon('server', 16) + '</div>' +
      '<nav class="wnav">' + nav + '</nav><div class="wside-fill"></div>' + card +
      '<button class="wuser' + (navKey === 'profile' ? ' is-on' : '') + '" data-route="profile" aria-label="Профиль">' + KV.avatar(A.user.name) + '<span class="wuser-t"><b>' + esc(A.user.name) + '</b><span>' + esc(A.roleLabel()) + ' · профиль</span></span>' + icon('chevronRight', 16) + '</button></aside><div class="wa-navscrim" data-nav-close="1"></div>';
  }

  /** Верхняя строка страницы: заголовок, пояснение, действия, переключатель темы. */
  A.top_ = function (o) {
    return '<header class="wtop"><button class="wbtn ghost icon wa-menu" data-nav-toggle="1" aria-label="Меню разделов" aria-expanded="false">' + icon('menu', 20) + '</button><div class="wtop-t"><h1>' + esc(o.title) + '</h1>' + (o.sub ? '<p>' + esc(o.sub) + '</p>' : '') + '</div><div class="wtop-r">' + (o.actions || '') +
      '<button class="wbtn secondary icon wa-theme" data-theme-toggle="1" aria-label="Сменить тему" title="Светлая или тёмная тема">' + icon(root.getAttribute('data-theme') === 'dark' ? 'sun' : 'moon', 18) + '</button>' +
      W.btn('', { kind: 'secondary', icon: 'refresh', label: 'Обновить', title: 'Обновить данные', attrs: 'data-reload="1"' }) + '</div></header>';
  };

  var current = null, token = 0;
  var LIVE_MS = 1500, NEW_MS = 8000, live = null, fresh = {};
  /** Строки, по которым видно появление нового: строки таблиц и элементы списков основной панели. */
  function rowsOf(main) { return main.querySelectorAll('.wmain-in tbody tr, .wmain-in .wli'); }
  function rowText(r) { return r.textContent.replace(/только что/g, '').replace(/\s+/g, ' ').trim(); }
  function rowSet(main) { var set = {}; Array.prototype.forEach.call(rowsOf(main), function (r) { set[rowText(r)] = 1; }); return set; }
  /** Помечает новые и изменившиеся строки на несколько секунд, чтобы зритель заметил изменение. */
  function markNew(main, before) {
    var now = Date.now();
    Array.prototype.forEach.call(rowsOf(main), function (r) {
      var t = rowText(r);
      if (!before[t] && !fresh[t]) fresh[t] = now + NEW_MS;
      if (fresh[t] && fresh[t] > now) {
        r.setAttribute('data-new', '1'); r.style.setProperty('--new-left', ((fresh[t] - now) / 1000).toFixed(1) + 's');
        setTimeout(function () { r.removeAttribute('data-new'); }, fresh[t] - now);
      }
    });
    Object.keys(fresh).forEach(function (t) { if (fresh[t] <= now) delete fresh[t]; });
  }
  /** Пользователь работает со страницей: открыт диалог, введён поиск, выбран фильтр - обновление ждёт. */
  function userBusy(main) {
    if (A.top() || document.hidden) return true;
    var a = document.activeElement;
    if (a && /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName) && main.contains(a)) return true;
    var q = main.querySelector('[data-wfilter]');
    if (q && q.value) return true;
    return filterKeys(main) !== main.__filters;
  }
  function filterKeys(main) {
    return Array.prototype.map.call(main.querySelectorAll('.wfilters'), function (g) { var on = g.querySelector('.wf.is-on'); return on ? on.getAttribute('data-key') : ''; }).join('|');
  }
  /** Ключ узла для сопоставления при обновлении: строки и карточки с идентификатором. */
  var KEYS = ['data-key', 'data-user', 'data-eq', 'data-role-open', 'data-log', 'id'];
  function keyOf(n) {
    if (n.nodeType !== 1) return null;
    for (var i = 0; i < KEYS.length; i++) { var v = n.getAttribute(KEYS[i]); if (v) return n.tagName + '|' + KEYS[i] + '|' + v; }
    return null;
  }
  function isRow(n) { return n.nodeType === 1 && (n.tagName === 'TR' || n.classList.contains('wli')); }
  function sameKind(a, b) { return a.nodeType === b.nodeType && (a.nodeType !== 1 || a.tagName === b.tagName); }
  /** Приводит атрибуты и потомков узла a к узлу b, не пересоздавая совпадающие узлы. */
  function patch(a, b) {
    if (a.nodeType !== 1) { if (a.nodeValue !== b.nodeValue) a.nodeValue = b.nodeValue; return; }
    if (isRow(b)) a.__h = b.outerHTML;
    var i, at;
    for (i = a.attributes.length - 1; i >= 0; i--) { at = a.attributes[i].name; if (!b.hasAttribute(at)) a.removeAttribute(at); }
    for (i = 0; i < b.attributes.length; i++) { at = b.attributes[i]; if (a.getAttribute(at.name) !== at.value) a.setAttribute(at.name, at.value); }
    if ((a.tagName === 'INPUT' || a.tagName === 'TEXTAREA') && a !== document.activeElement && a.value !== b.value) a.value = b.value;
    morph(a, b);
  }
  /** Обновляет потомков узла from по образцу to: совпавшие по ключу или содержимому строки переставляются, остальные правятся на месте. */
  function morph(from, to) {
    var olds = Array.prototype.slice.call(from.childNodes), news = Array.prototype.slice.call(to.childNodes);
    var keyed = {}, byHtml = {}, pos = 0, ref = from.firstChild;
    olds.forEach(function (n) {
      var k = keyOf(n);
      if (k) (keyed[k] = keyed[k] || []).push(n);
      else if (isRow(n)) { var h = n.__h || n.outerHTML; (byHtml[h] = byHtml[h] || []).push(n); }
    });
    news.forEach(function (nn) {
      var k = keyOf(nn), match = null, exact = false;
      if (k) { if (keyed[k] && keyed[k].length) match = keyed[k].shift(); }
      else {
        if (isRow(nn)) { var list = byHtml[nn.outerHTML]; while (list && list.length && !match) { var c0 = list.shift(); if (!c0.__used) { match = c0; exact = true; } } }
        if (!match) {
          while (pos < olds.length && (olds[pos].__used || keyOf(olds[pos]))) pos++;
          if (pos < olds.length && sameKind(olds[pos], nn)) match = olds[pos++];
        }
      }
      if (match) {
        match.__used = true;
        if (!exact) patch(match, nn);
        if (match === ref) ref = ref.nextSibling; else from.insertBefore(match, ref);
      } else {
        if (isRow(nn)) nn.__h = nn.outerHTML;
        from.insertBefore(nn, ref);
      }
    });
    olds.forEach(function (n) { if (n.__used) delete n.__used; else if (n.parentNode === from) from.removeChild(n); });
  }
  /** Обработчики, назначенные страницей в after: перед повторным назначением прежние снимаются. */
  var bound = [];
  function unbind() { bound.forEach(function (b) { b[0].removeEventListener(b[1], b[2], b[3]); }); bound = []; }
  function runAfter(page, main, data) {
    unbind();
    if (!page.after) return;
    var proto = EventTarget.prototype, orig = proto.addEventListener;
    proto.addEventListener = function (type, fn, opts) { if (this === main || (this.nodeType === 1 && main.contains(this))) bound.push([this, type, fn, opts]); return orig.call(this, type, fn, opts); };
    try { page.after(main, data, current.params); } finally { proto.addEventListener = orig; }
  }
  function signature(page, data) { try { return page.sig ? page.sig(data) : JSON.stringify(data); } catch (e) { return String(Math.random()); } }
  /** Рисует страницу по данным. При живом обновлении новая разметка переносится в существующие узлы:
   * меняются только отличающиеся строки и значения, прокрутка и фокус остаются на месте. */
  function paint(main, page, key, data, again) {
    var before = again ? rowSet(main) : null;
    if (again && A.stopTimers) A.stopTimers();
    var o = page.render(data, current.params);
    var box = document.createElement('section');
    box.innerHTML = A.top_(o) + (o.banner || '') + '<div class="wmain-in">' + (o.body || '') + '</div>';
    var top = box.querySelector('.wtop-t p');
    if (top && page.live !== false) top.insertAdjacentHTML('beforeend', ' <span class="wlive" title="Данные обновляются автоматически каждые 1,5 с"><i></i>онлайн</span>');
    W.typo(box);
    if (again) morph(main, box);
    else { main.textContent = ''; while (box.firstChild) main.appendChild(box.firstChild); }
    KV.layoutSegs(main);
    var stg = main.querySelector('.wmain-in'), i = 0;
    if (!again && stg && !A.still()) {
      Array.prototype.forEach.call(stg.children, function (c) { if (i < 8) { c.classList.add('stg'); c.style.setProperty('--i', i++); } });
      stg.classList.add('wa-enter');
      root.classList.add('is-appearing');
      clearTimeout(root.__appearT);
      root.__appearT = setTimeout(function () { root.classList.remove('is-appearing'); }, 900);
    }
    runAfter(page, main, data);
    var rl = main.querySelector('[data-reload]');
    if (rl) bound.push([rl, 'click', reloadNow, undefined]), rl.addEventListener('click', reloadNow);
    main.__filters = filterKeys(main);
    if (again) markNew(main, before);
  }
  function reloadNow() { if (current) A.go(current.key, current.params); }
  /** Живое обновление: страница перечитывает данные раз в 1,5 с и перерисовывается, только если они изменились. */
  function startLive(main, page, key, my, data) {
    if (live) clearTimeout(live);
    if (page.live === false || !page.load) return;
    var last = signature(page, data), busy = false;
    var tick = function () {
      live = null;
      if (my !== token || !document.contains(main)) return;
      if (busy || userBusy(main)) { live = setTimeout(tick, LIVE_MS); return; }
      busy = true;
      Promise.resolve(page.load(current.params)).then(function (fresh_) {
        busy = false;
        if (my !== token) return;
        var sig = signature(page, fresh_);
        if (sig !== last && !userBusy(main)) { last = sig; paint(main, page, key, fresh_, true); }
        live = setTimeout(tick, LIVE_MS);
      }, function () { busy = false; if (my === token) live = setTimeout(tick, LIVE_MS * 2); });
    };
    live = setTimeout(tick, LIVE_MS);
  }
  /** Показывает страницу: оболочка остаётся на месте, меняется только основная панель. */
  A.go = function (key, params) {
    A.closeAll();
    A.nav(false);
    unbind();
    if (A.stopTimers) A.stopTimers();
    if (live) { clearTimeout(live); live = null; }
    fresh = {};
    var page = A.pages[key];
    if (!page) { key = A.user ? A.home() : 'login'; page = A.pages[key]; }
    if (page.guard && !page.guard()) { key = A.user ? A.home() : 'login'; page = A.pages[key]; }
    if (location.hash !== '#/' + key) history.replaceState(null, '', '#/' + key);
    current = { key: key, params: params || {} };
    var my = ++token;
    if (page.full) {
      root.innerHTML = page.render(current.params);
      W.typo(root);
      if (page.after) page.after(root, current.params);
      return;
    }
    if (!root.querySelector(':scope > .wside') || root.__who !== A.user.id) {
      root.innerHTML = side(page.nav || key) + '<section class="wmain"></section>';
      root.__who = A.user.id;
    } else {
      Array.prototype.forEach.call(root.querySelectorAll('.wnav-item'), function (b) { b.classList.toggle('is-on', b.getAttribute('data-nav') === (page.nav || key)); });
      var u = root.querySelector('.wuser'); if (u) u.classList.toggle('is-on', key === 'profile');
    }
    var main = root.querySelector('.wmain');
    main.innerHTML = A.top_({ title: page.title, sub: 'Загрузка данных с сервера…' }) + '<div class="wmain-in"><div class="wa-load">' + W.skel('100%', 118, 18) + W.skel('100%', 280, 18) + W.skel('100%', 200, 18) + '</div></div>';
    Promise.resolve(page.load ? page.load(current.params) : null).then(function (data) {
      if (my !== token) return;
      paint(main, page, key, data, false);
      startLive(main, page, key, my, data);
    }, function (err) {
      if (my !== token) return;
      if (err && err.status === 401) return;
      main.innerHTML = A.top_({ title: page.title, sub: 'Данные не загружены' }) + '<div class="wmain-in">' +
        W.empty({ icon: 'alert', tone: 'bad', title: err && err.status === 0 ? 'Нет связи с сервером' : 'Не удалось загрузить данные', text: err && err.detail ? err.detail : String(err), action: W.btn('Повторить', { kind: 'primary', icon: 'refresh', attrs: 'data-reload="1"' }) }) + '</div>';
      Array.prototype.forEach.call(main.querySelectorAll('[data-reload]'), function (b) { b.addEventListener('click', function () { A.go(key, current.params); }); });
    });
  };
  A.reload = function () { if (current) A.go(current.key, current.params); };
  A.current = function () { return current; };
  A.page = function (key, def) { A.pages[key] = def; };

  window.addEventListener('hashchange', function () {
    var k = (location.hash || '').replace(/^#\/?/, '');
    if (A.user && k && (!current || k !== current.key)) A.go(k);
  });

  /** Заголовок пустых, ошибочных и недоступных состояний. */
  A.unavailable = function (title, text) { return W.empty({ icon: 'info', title: title, text: text }); };
  A.chip = function (t, s) { return KV.chip(t, s); };
})();
