/**
 * Общие страницы веб-панели: вход, первый вход с временным паролем, нет доступа, профиль и сводка мастера.
 */
(function () {
  'use strict';
  var KV = window.KV, W = KV.w, A = window.WA, esc = KV.esc, icon = KV.icon;

  function brand() {
    return '<div class="wlogin-brand"><span class="wlogin-word"><i></i>КСТ Визор</span><span class="wtag">' + icon('server', 12) + 'веб-панель</span></div>';
  }
  function art() {
    return '<div class="wlogin-art" style="background-image:url(\'assets/hero.jpg\')">' + KV.logo('white', 30) +
      '<p>КСТ Визор · цеховой сервер насосной станции № 2. Работает в сети цеха без выхода в интернет: осмотры, диагностика и учёт оборудования.</p></div>';
  }
  function foot() { return '<div class="wlogin-foot"><i class="dot unk" data-health-dot="1"></i><span data-health="1">Сервер ' + esc(location.host) + ' · проверка связи…</span></div>'; }
  function loginShell(form) {
    return '<div class="wlogin"><div class="wlogin-bg" style="background-image:url(\'assets/hero.jpg\')"></div>' +
      '<div class="wlogin-card"><div class="wlogin-form">' + brand() + form + foot() + '</div>' + art() + '</div></div>';
  }
  function health(root) {
    A.raw('GET', '/health').then(function (r) {
      var dot = root.querySelector('[data-health-dot]'), t = root.querySelector('[data-health]');
      if (!dot) return;
      var ok = r.status === 200 && r.body && r.body.ok;
      dot.className = 'dot ' + (ok ? 'ok' : 'bad');
      t.textContent = ok ? 'Сервер ' + location.host + ' · база данных в порядке · оборудования: ' + r.body.equipment : 'Сервер ' + location.host + ' не отвечает';
    });
  }
  function device() {
    var ua = navigator.userAgent, b = /Firefox\/(\d+)/.exec(ua) || /Edg\/(\d+)/.exec(ua) || /Chrome\/(\d+)/.exec(ua) || /Version\/(\d+).*Safari/.exec(ua);
    var name = /Firefox/.test(ua) ? 'Firefox' : /Edg\//.test(ua) ? 'Edge' : /Chrome/.test(ua) ? 'Chrome' : /Safari/.test(ua) ? 'Safari' : 'браузер';
    return 'Веб-панель · ' + name + (b ? ' ' + b[1] : '');
  }

  var pending = { email: '', password: '' };

  A.page('login', { full: true,
    render: function (p) {
      p = p || {};
      var locked = p.locked;
      return loginShell('<h1>Вход в веб-панель</h1><p class="wlead">Для администраторов системы и ИБ; мастеру - просмотр сводки. Учётные записи выдаёт администратор ИБ.</p>' +
        '<form class="wform" data-login="1" novalidate>' +
        W.field({ label: 'Рабочая почта', value: p.email || '', lead: 'mail', lg: true, type: 'email', name: 'email', placeholder: 'name@kst-energo.ru', attrs: 'data-autofocus="1" required' }) +
        W.pw({ label: 'Пароль', value: '', lead: 'lock', lg: true, name: 'password', error: p.error, help: p.error || '', placeholder: 'Пароль',
          hint: '<button type="button" class="wlink" data-forgot="1">Забыли пароль?</button>' }) +
        (locked ? W.note('<b>Вход временно закрыт.</b> Слишком много неудачных попыток с этого адреса. Повторите через <span data-wcount="' + locked + '">' + A.pad(Math.floor(locked / 60)) + ':' + A.pad(locked % 60) + '</span>.', { tone: 'warn', icon: 'timer' }) : '') +
        '<button class="wbtn primary lg wide' + (locked ? '' : '') + '" type="submit" data-login-go="1"' + (locked ? ' disabled' : '') + '><span>' + (locked ? 'Вход закрыт' : 'Войти') + '</span>' + icon('arrowRight', 18) + '</button>' +
        '<div class="wrow wmicro">' + icon('shieldCheck', 16) + '<span>Каждый вход и неудачная попытка записываются в журнал безопасности</span></div></form>');
    },
    after: function (root, p) {
      health(root);
      var form = root.querySelector('[data-login]');
      var eye = root.querySelectorAll('[data-weye]');
      Array.prototype.forEach.call(eye, function (b) { b.setAttribute('type', 'button'); });
      var cnt = root.querySelector('[data-wcount]');
      if (cnt) {
        var left = +cnt.getAttribute('data-wcount');
        var tick = setInterval(function () {
          if (!document.contains(cnt)) { clearInterval(tick); return; }
          left = Math.max(0, left - 1);
          cnt.textContent = A.pad(Math.floor(left / 60)) + ':' + A.pad(left % 60);
          if (!left) { clearInterval(tick); A.go('login', { email: p && p.email }); }
        }, 1000);
      }
      root.querySelector('[data-forgot]').addEventListener('click', function () {
        A.open(W.modal({ icon: 'key', title: 'Пароль выдаёт администратор ИБ', text: 'Сервер работает без почты и интернета, поэтому ссылку для сброса не отправить. Администратор ИБ выдаст временный пароль лично, при входе вы зададите свой.', size: 's',
          actions: W.btn('Понятно', { kind: 'primary', close: true }) }));
      });
      form.addEventListener('submit', function (e) {
        e.preventDefault();
        var email = form.email.value.trim(), password = form.password.value;
        if (!email || !password) { A.toast('Не удалось войти', 'Укажите рабочую почту и пароль', 'bad'); return; }
        var btn = form.querySelector('[data-login-go]');
        A.busy(btn, A.raw('POST', '/auth/login', { email: email, password: password, device: device() })).then(function (r) {
          if (r.status === 200) {
            A.saveTokens(r.body);
            A.user = r.body.user;
            if (r.body.must_change_password) { pending = { email: email, password: password }; A.go('temp'); return; }
            A.enter();
            return;
          }
          var detail = r.body && typeof r.body.detail === 'string' ? r.body.detail : 'Ошибка сервера (' + r.status + ')';
          if (r.status === 403) { A.go('blocked', { email: email, detail: detail }); return; }
          if (r.status === 429) {
            var wait = +(r.headers && r.headers.get('Retry-After')) || 60;
            A.go('login', { email: email, locked: wait });
            A.toast('Вход временно закрыт', detail, 'warn', 'timer');
            return;
          }
          if (r.status === 0) { A.toast('Нет связи с сервером', 'Проверьте сеть цеха и адрес ' + location.host, 'bad'); return; }
          A.go('login', { email: email, error: detail });
          A.toast('Не удалось войти', detail + '. После нескольких неудачных попыток вход временно закрывается.', 'bad');
        });
      });
    } });

  A.page('blocked', { full: true,
    render: function (p) {
      return loginShell('<div class="wcol l" style="margin-top:34px"><span class="wmodal-ic bad">' + icon('lock', 22) + '</span><h1 style="margin-top:4px">Учётная запись заблокирована</h1>' +
        '<p class="wlead" style="margin-top:0">' + esc(p.email || '') + ' · ' + esc(p.detail || '') + '.</p>' +
        W.note('Администратор ИБ снимет блокировку или выдаст новую учётную запись. Попытка входа записана в журнал безопасности.', { icon: 'info' }) +
        '<div class="wrow">' + W.btn('Ко входу', { kind: 'secondary', icon: 'arrowLeft', attrs: 'data-route="login"' }) + '</div></div>');
    },
    after: function (root) { health(root); } });

  /** Проверки нового пароля по политике прямо при вводе. */
  function passChecks(f, minLen) {
    var p1 = f.querySelector('[data-p1]'), p2 = f.querySelector('[data-p2]'), go = f.querySelector('.wpass-go');
    var run = function () {
      var a = p1.value, b = p2.value;
      var r = { len: a.length >= minLen, mix: /[A-Za-zА-Яа-яЁё]/.test(a) && /\d/.test(a), edge: a === a.trim() && a.length > 0, same: !!a && a === b };
      var all = true;
      Object.keys(r).forEach(function (k) {
        var row = f.querySelector('[data-chk="' + k + '"]'); if (!row) return;
        row.className = 'wchk ' + (r[k] ? 'ok' : 'bad'); row.querySelector('i').innerHTML = icon(r[k] ? 'check' : 'close', 12);
        if (!r[k]) all = false;
      });
      [p1, p2].forEach(function (p) { p.closest('.winput').classList.toggle('is-error', !all && p.value.length > 0 && (p === p1 ? !(r.len && r.mix && r.edge) : !r.same)); });
      if (go) go.disabled = !all;
    };
    p1.addEventListener('input', run); p2.addEventListener('input', run);
    run();
  }
  function passForm(minLen, current) {
    return '<form class="wform" data-wpass="1" novalidate>' +
      (current ? W.pw({ label: 'Текущий пароль', lead: 'lock', lg: true, name: 'current', attrs: 'data-p0="1"' }) : '') +
      W.pw({ label: 'Новый пароль', lead: 'lock', lg: true, attrs: 'data-p1="1" data-autofocus="1"' }) +
      W.pw({ label: 'Повторите пароль', lead: 'lock', lg: true, attrs: 'data-p2="1"' }) +
      '<div class="wchecks">' + [['len', 'Не короче ' + minLen + ' символов'], ['mix', 'Есть буквы и цифры'], ['edge', 'Без пробелов в начале и в конце'], ['same', 'Пароли совпадают']].map(function (c) {
        return '<div class="wchk" data-chk="' + c[0] + '"><i></i><span>' + c[1] + '</span></div>'; }).join('') + '</div>' +
      '<button class="wbtn primary lg wide wpass-go" type="submit"><span>' + (current ? 'Сменить пароль' : 'Сохранить и войти') + '</span></button></form>';
  }
  A.passForm = passForm; A.passChecks = passChecks;

  A.page('temp', { full: true,
    render: function () {
      return loginShell('<h1>Смена временного пароля</h1><p class="wlead">' + esc(A.user ? A.user.email : '') + ' · временный пароль выдал администратор ИБ. Задайте постоянный пароль, чтобы продолжить.</p>' + passForm(10, !pending.password));
    },
    after: function (root) {
      health(root);
      Array.prototype.forEach.call(root.querySelectorAll('[data-weye]'), function (b) { b.setAttribute('type', 'button'); });
      var f = root.querySelector('[data-wpass]');
      passChecks(f, 10);
      f.addEventListener('submit', function (e) {
        e.preventDefault();
        var cur = pending.password || (f.querySelector('[data-p0]') || {}).value;
        var next = f.querySelector('[data-p1]').value;
        A.busy(f.querySelector('.wpass-go'), A.post('/auth/password', { current_password: cur, new_password: next })).then(function (r) {
          pending = { email: '', password: '' };
          A.user = r.user;
          A.enter();
          A.toast('Пароль сохранён', 'Постоянный пароль задан. Прочие сеансы закрыты, событие записано в журнал безопасности.', 'ok', 'key');
        }, function (err) { A.fail(err, 'Пароль не принят'); });
      });
    } });

  A.page('noaccess', { full: true, guard: function () { return !!A.user; },
    render: function () {
      return loginShell('<div class="wcol l" style="margin-top:34px"><span class="wmodal-ic">' + icon('phone', 22) + '</span><h1 style="margin-top:4px">Для роли ' + esc(A.roleLabel()) + ' разделов веб-панели нет</h1>' +
        '<p class="wlead" style="margin-top:0">' + esc(A.user.email) + ' · осмотры, находки, задания и отчёты доступны в приложении КСТ Визор на телефоне.</p>' +
        W.note('Веб-панель открыта ролям Админ и Админ ИБ, мастеру - сводка смены без изменений.', { icon: 'info' }) +
        '<div class="wrow">' + W.btn('Выйти', { kind: 'secondary', icon: 'logout', attrs: 'data-logout="1"' }) + '</div></div>');
    },
    after: function (root) {
      health(root);
      root.querySelector('[data-logout]').addEventListener('click', function () { A.logout(); });
    } });

  A.logout = function () {
    var done = function () { A.user = null; A.clearTokens(); A.go('login'); };
    A.raw('POST', '/auth/logout', {}, A.store.get('access')).then(done, done);
  };

  /** Профиль: сведения о сотруднике, права, тема оформления, смена пароля и выход. */
  A.page('profile', { title: 'Профиль', guard: function () { return !!A.user; },
    load: function () { return A.get('/auth/me'); },
    render: function (me) {
      A.user = me;
      var th = A.root.getAttribute('data-theme');
      var perms = me.permissions.length ? '<div class="wa-classes">' + me.permissions.map(function (p) { return W.tag(p, 'mono'); }).join('') + '</div>' : '<p class="wlabel">Прав нет</p>';
      return { title: 'Профиль · ' + A.roleLabel(), sub: me.name + ' · ' + me.email,
        actions: W.btn('Выйти', { kind: 'secondary', icon: 'logout', attrs: 'data-logout="1"' }),
        body: '<div class="wgrid wg-side"><div class="wcol l">' +
          W.panel({ title: 'Учётная запись', body: '<div class="wrow" style="gap:14px;margin-bottom:14px">' + KV.avatar(me.name, 'lg') + '<div class="wcol s"><b>' + esc(me.name) + '</b><span class="wlabel">' + esc(me.email) + '</span></div></div>' +
            W.kv([['Роль', me.role_title], ['Код роли', '<span class="wmono">' + esc(me.role) + '</span>', true], ['Прав у роли', String(me.permissions.length)]]) }) +
          W.panel({ title: 'Права роли', sub: 'Назначает администратор ИБ; сервер проверяет их на каждом запросе', body: perms }) +
        '</div><div class="wcol l">' +
          W.panel({ title: 'Оформление', sub: 'Тема панели в этом браузере', body: KV.segment(['Светлая', 'Тёмная'], th === 'dark' ? 1 : 0, { cls: 'wa-theme-seg' }) }) +
          W.panel({ title: 'Безопасность', sub: 'Смена пароля закрывает прочие сеансы', body: W.btn('Сменить пароль', { kind: 'secondary', icon: 'key', attrs: 'data-pass="1"' }) }) +
        '</div></div>' };
    },
    after: function (main) {
      main.querySelector('[data-logout]').addEventListener('click', function () {
        A.open(W.modal({ icon: 'logout', title: 'Выйти из веб-панели?', text: 'Сеанс этого браузера закроется сразу. Сеансы на телефоне не затрагиваются.', size: 's',
          actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Выйти', { kind: 'primary', icon: 'logout', attrs: 'data-logout-ok="1"' }) })).querySelector('[data-logout-ok]').addEventListener('click', function () { A.logout(); });
      });
      var seg = main.querySelector('.wa-theme-seg');
      if (seg) seg.addEventListener('click', function () { setTimeout(function () { var on = seg.querySelectorAll('.seg-item')[1].classList.contains('is-on'); A.theme(on ? 'dark' : 'light'); }, 0); });
      main.querySelector('[data-pass]').addEventListener('click', function () {
        var ov = A.open(W.modal({ icon: 'key', title: 'Смена пароля', text: 'Новый пароль должен соответствовать политике безопасности сервера.', size: 'm', body: passForm(10, true) }));
        var f = ov.querySelector('[data-wpass]');
        Array.prototype.forEach.call(ov.querySelectorAll('[data-weye]'), function (b) { b.setAttribute('type', 'button'); });
        passChecks(f, 10);
        f.addEventListener('submit', function (e) {
          e.preventDefault();
          A.busy(f.querySelector('.wpass-go'), A.post('/auth/password', { current_password: f.querySelector('[data-p0]').value, new_password: f.querySelector('[data-p1]').value })).then(function () {
            A.close(ov); A.toast('Пароль изменён', 'Прочие сеансы закрыты, событие записано в журнал безопасности', 'ok', 'key');
          }, function (err) { A.fail(err, 'Пароль не изменён'); });
        });
      });
    } });

  /** Сводка смены мастера: живая картина смены - текущий осмотр, замечания и решения по ним, звук, телеметрия. */
  var STATE = { open: ['Открыто', 'warn'], in_work: ['В работе', 'info'], resolved: ['Устранено', 'ok'], rejected: ['Отклонено', 'unk'] };
  var LEVEL = { ok: ['норма', 'ok'], warn: ['внимание', 'warn'], alarm: ['тревога', 'bad'] };
  var FTONE = { defect: 'bad', check: 'warn', ok: 'ok' };
  function soft(p) { return p.catch(function () { return null; }); }
  function summaryLoad() {
    return Promise.all([A.get('/equipment'), soft(A.get('/inspections/findings?limit=60&include_rejected=true')), soft(A.get('/inspections?limit=20')),
      soft(A.get('/inspections/sound/recent?limit=6')), soft(A.get('/notifications?limit=8')), soft(A.get('/site'))]).then(function (d) {
      var eq = d[0], ins = d[2] || [];
      var active = ins.filter(function (i) { return i.status === 'active'; })[0];
      var tele = eq.filter(function (u) { return u.telemetry; })[0];
      return Promise.all([active ? soft(A.get('/inspections/' + active.id)) : null, tele ? soft(A.get('/equipment/' + encodeURIComponent(tele.id) + '/telemetry')) : null]).then(function (x) {
        return { eq: eq, findings: d[1] || [], ins: ins, sounds: d[3] || [], notes: d[4] || [], site: d[5], current: x[0], tele: x[1], teleUnit: tele };
      });
    });
  }
  function stateChip(f) { var st = STATE[f.state] || [f.state, '']; return A.chip(st[0], st[1]); }
  function findingRow(f) {
    var sub = (f.node_name || '') + (f.rule_id ? ' · ' + f.rule_id : '') + (f.rejected && f.reject_reason ? ' · причина: ' + f.reject_reason : '');
    var who = f.rejected && f.rejected_by ? f.rejected_by.name + ', ' + A.dt(f.rejected_at, { time: true }) : A.dt(f.created_at);
    return { cells: ['<span class="wmono">' + esc(f.id) + '</span>', esc(f.equipment_id || ''), '<div class="wcell"><div><span class="t-main">' + esc(f.title) + '</span><span class="t-sub">' + esc(sub) + '</span></div></div>',
      A.chip(f.status === 'defect' ? 'Дефект' : f.status === 'check' ? 'Проверить' : 'Норма', FTONE[f.status] || 'unk'), stateChip(f), '<span class="wt-3">' + esc(who) + '</span>'] };
  }
  function currentPanel(d) {
    var c = d.current;
    if (!c) return W.panel({ title: 'Текущий осмотр', sub: 'Сейчас осмотров нет', body: '<p class="wlabel" style="padding:8px 4px">Как только инженер начнёт осмотр в приложении, он появится здесь.</p>' });
    var cov = c.coverage || {}, pct = cov.percent || 0;
    var items = (c.findings || []).slice().reverse().slice(0, 6).map(function (f) {
      return W.li({ tone: f.rejected ? 'unk' : FTONE[f.status] || 'info', icon: f.kind === 'checked' ? 'checkCircle' : f.rejected ? 'close' : 'alert', title: f.title + (f.rejected ? ' · отклонено' : ''),
        text: (f.node_name || '') + ' · ' + (STATE[f.state] || [f.state])[0].toLowerCase() + (f.confidence != null ? ' · уверенность ' + KV.num(f.confidence, 2) : ''), right: A.dt(f.created_at, { time: true }) });
    }).join('');
    return W.panel({ title: 'Текущий осмотр № ' + c.id + ' · ' + c.equipment_id, sub: (c.user ? c.user.name : '') + ' · начат ' + A.dt(c.started_at, { time: true }) + (c.identified_title ? ' · ' + c.identified_title.toLowerCase() : ''),
      right: A.chip('Идёт', 'info'), body: W.meter('Полнота обхода', (cov.inspected || 0) + ' из ' + (cov.total || 0) + ' узлов · ' + pct + ' %', pct, pct >= 80 ? 'ok' : '') +
        (cov.hint ? '<p class="wmicro" style="margin:6px 0 10px">' + esc(cov.hint) + '</p>' : '') +
        (items ? '<div class="wlist">' + items + '</div>' : '<p class="wlabel" style="padding:8px 4px">Записей в осмотре пока нет.</p>') });
  }
  function telePanel(d) {
    if (!d.tele || !d.tele.available) return '';
    var rows = d.tele.parameters.filter(function (p) { return p.level; }).slice(0, 8).map(function (p) {
      var lv = LEVEL[p.level] || ['', ''];
      return W.li({ tone: lv[1], icon: 'wave', title: p.name, text: lv[0] + (p.warn != null ? ' · уставка ' + KV.num(p.warn) + ' ' + (p.unit || '') : ''), right: '<span class="wnum">' + KV.num(p.value, Math.abs(p.value) < 10 ? 2 : 1) + '</span> ' + esc(p.unit || '') });
    }).join('');
    return W.panel({ title: 'Телеметрия ' + d.teleUnit.id, sub: 'Показания на ' + A.dt(d.tele.at) + (d.tele.level_title ? ' · ' + d.tele.level_title.toLowerCase() : ''), body: '<div class="wlist">' + rows + '</div>' });
  }
  function soundPanel(d) {
    var rows = d.sounds.map(function (r) {
      var c = r.candidates || [];
      return W.li({ tone: c.length ? 'warn' : 'ok', icon: 'wave', title: r.equipment_id + ' · осмотр № ' + r.inspection_id + (r.normal ? ' · норма' : ''),
        text: (c.length ? c.map(function (x) { return x.text; }).join('; ') : 'признаков не выявлено') + ' · уровень ' + KV.num(r.level_dbfs, 1) + ' дБ', right: A.dt(r.created_at, { time: true }) });
    }).join('');
    return W.panel({ title: 'Записи звука', sub: 'Кандидаты по звуку подтверждает инженер', body: rows ? '<div class="wlist">' + rows + '</div>' : '<p class="wlabel" style="padding:8px 4px">Записей звука пока нет.</p>' });
  }
  function notesPanel(d) {
    var rows = d.notes.map(function (n) { return W.li({ tone: n.kind === 'fault_report_new' ? 'warn' : 'info', icon: 'bell', title: n.title, text: n.text, right: A.dt(n.at, { time: true }) }); }).join('');
    return W.panel({ title: 'Уведомления', sub: 'Задания и сообщения о неисправностях', body: rows ? '<div class="wlist">' + rows + '</div>' : '<p class="wlabel" style="padding:8px 4px">Новых уведомлений нет.</p>' });
  }
  A.page('summary', { title: 'Сводка смены', guard: function () { return A.isMaster(); },
    load: summaryLoad,
    render: function (d) {
      var eq = d.eq, fs = d.findings, ins = d.ins;
      var open = fs.filter(function (f) { return f.state === 'open' || f.state === 'in_work'; });
      var today = new Date(); today.setHours(0, 0, 0, 0);
      var rejectedToday = fs.filter(function (f) { return f.rejected && f.rejected_at && new Date(f.rejected_at) >= today; }).length;
      var rows = eq.map(function (u) {
        return { cells: ['<div class="wcell"><div><span class="t-main">' + esc(u.id) + ' · ' + esc(u.name) + '</span><span class="t-sub">' + esc(u.model) + '</span></div></div>', esc(u.location),
          A.chip(u.mode === 'running' ? 'В работе' : 'Остановлен', u.mode === 'running' ? 'ok' : 'unk'), KV.num(u.run_hours, 0) + ' ч', u.open_findings ? A.chip(String(u.open_findings), 'warn') : '<span class="wt-3">нет</span>', A.dt(u.last_inspection_at, { date: true })] };
      });
      var irows = ins.slice(0, 10).map(function (i) {
        var sm = i.summary || {};
        return { cells: ['<span class="wmono">' + esc(i.id) + '</span>', esc(i.equipment_id), esc(i.user ? i.user.name : ''), A.chip(i.status_title, i.status === 'active' ? 'info' : 'ok'),
          A.dt(i.started_at), i.status === 'active' ? '<span class="wt-3">идёт</span>' : esc((sm.findings != null ? 'записей ' + sm.findings : '') + (sm.rejected ? ' · отклонено ' + sm.rejected : ''))] };
      });
      var site = d.site;
      return { title: 'Сводка смены', sub: (site ? site.name + ' · ' + site.shift_title.toLowerCase() + ' ' + site.shift + ' · ' : '') + 'подтверждение находок и план ТО - в приложении на телефоне',
        body: W.kpis([{ label: 'Агрегатов', icon: 'box', value: String(eq.length), note: eq.filter(function (u) { return u.mode === 'running'; }).length + ' в работе' },
          { label: 'Идёт осмотров', icon: 'clipboard', value: String(ins.filter(function (i) { return i.status === 'active'; }).length), note: 'в списке ' + ins.length },
          { label: 'Открытые замечания', icon: 'alert', value: String(open.length), status: open.length ? 'warn' : '', note: 'открыто и в работе' },
          { label: 'Отклонено сегодня', icon: 'close', value: String(rejectedToday), note: 'ложные находки' }]) +
          '<div class="wgrid wg-21">' + currentPanel(d) + '<div class="wcol l">' + telePanel(d) + soundPanel(d) + '</div></div>' +
          W.sec({ title: 'Замечания и решения', sub: 'Новые, подтверждённые и отклонённые - сначала новые', body: fs.length ? W.table([{ label: '№' }, { label: 'Агрегат' }, { label: 'Замечание' }, { label: 'Статус' }, { label: 'Состояние' }, { label: 'Когда', cls: 'nw' }], fs.slice(0, 15).map(findingRow), { dense: true }) : W.empty({ icon: 'checkCircle', title: 'Замечаний нет', text: 'Новые замечания появятся после осмотров инженеров.' }) }) +
          '<div class="wgrid wg-21">' + W.sec({ title: 'Осмотры', sub: 'Последние осмотры смены', body: W.table([{ label: '№' }, { label: 'Агрегат' }, { label: 'Инженер' }, { label: 'Состояние' }, { label: 'Начат', cls: 'nw' }, { label: 'Итог' }], irows, { dense: true }) }) + notesPanel(d) + '</div>' +
          W.sec({ title: 'Оборудование', body: W.table([{ label: 'Агрегат' }, { label: 'Место' }, { label: 'Режим' }, { label: 'Наработка', cls: 'nw' }, { label: 'Замечания' }, { label: 'Последний осмотр', cls: 'nw' }], rows) }) };
    } });
})();
