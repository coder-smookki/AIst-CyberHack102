/**
 * Страницы администратора ИБ: пользователи и сеансы, роли и матрица прав, журнал безопасности, политика.
 * Все данные и изменения идут через раздел /admin сервера; защиту от потери управления проверяет сервер.
 */
(function () {
  'use strict';
  var KV = window.KV, W = KV.w, A = window.WA, esc = KV.esc, icon = KV.icon, num = KV.num;
  var ST = { active: ['Активна', 'ok'], temp: ['Временный пароль', 'warn'], blocked: ['Заблокирована', 'bad'] };
  var REASONS = ['Перевод в другое подразделение', 'Увольнение', 'Утеря устройства', 'Подозрение на чужой вход'];
  var GUARD = ['users.manage', 'roles.manage'];
  var GUARD_TEXT = 'Изменение отклонено: не останется ни одной активной учётной записи с правами управления учётными записями и ролями';

  function status(u) { return !u.is_active ? 'blocked' : u.must_change_password ? 'temp' : 'active'; }
  function shortRole(code, title) { return code === 'security_admin' ? 'Админ ИБ' : code === 'admin' ? 'Админ' : title; }
  function isGuard(err) { return err && err.status === 409 && /не останется/.test(err.detail || ''); }

  /** Диалог защиты от потери управления с текстом отказа сервера. */
  function guardModal(detail, fix) {
    var ov = A.open(W.modal({ icon: 'shield', tone: 'bad', title: 'Сервер отклонил изменение', text: 'Не останется ни одной активной учётной записи с правами управления учётными записями и ролями.', size: 'm', body:
      W.note(esc(detail || GUARD_TEXT), { tone: 'bad', icon: 'alert' }) +
      '<div class="wdsec"><h3>Как сделать безопасно</h3><div class="wlist">' + W.li({ icon: 'userPlus', title: 'Назначьте второго администратора ИБ', text: 'Роль Админ ИБ ещё одному активному сотруднику' }) +
        W.li({ icon: 'key', title: 'Или выдайте оба права другой роли', text: '«Управление учётными записями» и «Управление ролями» роли с активным сотрудником' }) + '</div></div>',
      actions: W.btn('Понятно', { kind: 'ghost', close: true }) + (fix ? W.btn('Вернуть права', { kind: 'primary', icon: 'rollback', attrs: 'data-guard-fix="1"' }) : '') }));
    if (fix) ov.querySelector('[data-guard-fix]').addEventListener('click', function () { fix(); A.close(ov); });
    return ov;
  }
  A.guardModal = guardModal;

  function secretBlock(pw) {
    return '<div class="wsecret"><code data-secret="1">' + esc(pw) + '</code>' + W.btn('Скопировать', { kind: 'secondary', size: 'sm', icon: 'copy', attrs: 'data-copy="1"' }) + '</div>';
  }
  function bindCopy(ov, pw) {
    var b = ov.querySelector('[data-copy]');
    if (b) b.addEventListener('click', function () {
      A.copy(pw).then(function (ok) { A.toast(ok ? 'Пароль скопирован' : 'Не удалось скопировать', ok ? 'Передайте его сотруднику лично' : 'Выделите пароль и скопируйте вручную', ok ? 'ok' : 'warn', 'copy'); });
    });
  }

  /* ---------- Пользователи ---------- */
  var cache = { roles: [], users: [] };

  A.page('users', { title: 'Пользователи', guard: function () { return A.can('users.manage'); },
    load: function () { return Promise.all([A.get('/admin/users'), A.get('/admin/roles')]); },
    render: function (d) {
      var list = d[0], roles = d[1];
      cache.users = list; cache.roles = roles;
      var c = { all: list.length, active: 0, temp: 0, blocked: 0, sess: 0 };
      list.forEach(function (u) { c[status(u)]++; c.sess += u.active_sessions; });
      var rows = list.map(function (u) {
        var s = ST[status(u)];
        return { key: status(u) + ' ' + u.role, text: u.name + ' ' + u.email + ' ' + u.role_title, attrs: '', cls: '', act: null, id: u.id,
          cells: ['<div class="wcell">' + KV.avatar(u.name) + '<div><span class="t-main">' + esc(u.name) + (u.id === A.user.id ? ' <span class="wt-3">· вы</span>' : '') + '</span><span class="t-sub">' + esc(u.email) + '</span></div></div>',
            esc(shortRole(u.role, u.role_title)), A.chip(s[0], s[1]), u.last_login_at ? A.dt(u.last_login_at) : '<span class="wt-3">ещё не входил</span>',
            u.active_sessions ? String(u.active_sessions) : '<span class="wt-3">нет</span>', icon('chevronRight', 18)] };
      });
      var html = W.table([{ label: 'Сотрудник' }, { label: 'Роль' }, { label: 'Состояние' }, { label: 'Последний вход', cls: 'nw' }, { label: 'Сеансы' }, { label: '', cls: 'chev' }], rows,
        { empty: W.empty({ icon: 'search', title: 'Сотрудники не найдены', text: 'Поиск идёт по имени и почте. Новую учётную запись создаёт кнопка «Создать учётную запись».' }) });
      list.forEach(function (u) { html = html.replace('data-text="' + esc(u.name + ' ' + u.email + ' ' + u.role_title) + '"', 'data-text="' + esc(u.name + ' ' + u.email + ' ' + u.role_title) + '" data-user="' + u.id + '" role="button" tabindex="0"'); });
      return { title: 'Пользователи', sub: 'Вход в приложение и веб-панель по одной учётной записи · данные GET /admin/users',
        actions: W.btn('Создать учётную запись', { kind: 'primary', icon: 'userPlus', attrs: 'data-new-user="1"' }),
        body: W.kpis([{ label: 'Учётных записей', icon: 'users', value: String(c.all), note: 'на этом сервере' }, { label: 'Активные', icon: 'checkCircle', value: String(c.active), note: 'вход разрешён' },
          { label: 'Временный пароль', icon: 'key', value: String(c.temp), status: c.temp ? 'warn' : '', note: c.temp ? 'ещё не сменили' : 'нет' }, { label: 'Заблокированы', icon: 'ban', value: String(c.blocked), note: 'вход запрещён' },
          { label: 'Открытых сеансов', icon: 'phone', value: String(c.sess), note: 'телефоны и браузеры' }]) +
          '<div class="wcol"><div class="wtoolbar">' + W.search('Имя или почта') + W.filters([{ label: 'Все', count: c.all, key: '', on: true }, { label: 'Активные', count: c.active, key: 'active', dot: 'ok' }, { label: 'Временный пароль', count: c.temp, key: 'temp', dot: 'warn' }, { label: 'Заблокированы', count: c.blocked, key: 'blocked', dot: 'bad' }], { group: 'st' }) + '</div>' +
          W.filters([{ label: 'Все роли', key: '', on: true }].concat(roles.map(function (r) { return { label: shortRole(r.code, r.title), count: r.members, key: r.code }; })), { group: 'role' }) + '</div>' + html };
    },
    after: function (main) {
      W.bindFilter(main, {});
      main.querySelector('[data-new-user]').addEventListener('click', newUser);
      Array.prototype.forEach.call(main.querySelectorAll('[data-user]'), function (tr) {
        tr.addEventListener('click', function () { userDrawer(+tr.getAttribute('data-user')); });
      });
    } });

  function roleRadios(selected) {
    return W.radios(cache.roles.map(function (r) { return { title: shortRole(r.code, r.title), sub: r.permissions.length + ' прав · ' + r.description, right: r.members + ' сотр.', key: r.code, on: r.code === selected }; }));
  }
  function picked(ov, sel) { var on = ov.querySelector(sel + ' .is-on'); return on ? on.getAttribute('data-key') : null; }

  function newUser() {
    var ov = A.open(W.modal({ icon: 'userPlus', title: 'Новая учётная запись', text: 'Одна запись для приложения на телефоне и для веб-панели.', size: 'l', body:
      '<div class="wform-2">' + W.field({ label: 'Фамилия и имя', name: 'name', placeholder: 'Ирина Соколова', attrs: 'data-autofocus="1"' }) + W.field({ label: 'Рабочая почта', name: 'email', lead: 'mail', placeholder: 'i.sokolova@kst-energo.ru', help: 'Логин для входа, латиницей' }) + '</div>' +
      '<div class="wfield" data-roles="1"><span class="wfield-l"><span>Роль</span><span class="wmicro">права роли - в разделе «Роли и права»</span></span>' + roleRadios('engineer') + '</div>' +
      W.note('Временный пароль создаёт сервер и показывает один раз. При первом входе сотрудник задаёт свой пароль по политике безопасности.', { icon: 'key' }),
      actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Создать', { kind: 'primary', icon: 'check', attrs: 'data-create="1"' }) }));
    ov.querySelector('[data-create]').addEventListener('click', function (e) {
      var name = ov.querySelector('[name=name]').value.trim(), email = ov.querySelector('[name=email]').value.trim(), role = picked(ov, '[data-roles]');
      if (!name || !email) { A.toast('Заполните поля', 'Укажите фамилию, имя и рабочую почту', 'warn'); return; }
      A.busy(e.currentTarget, A.post('/admin/users', { name: name, email: email, role: role })).then(function (r) {
        var u = r.user, pw = r.temporary_password;
        var done = A.open(W.modal({ icon: 'checkCircle', tone: 'ok', title: 'Учётная запись создана', text: u.name + ' · ' + u.email + ' · роль ' + shortRole(u.role, u.role_title), size: 'm', noClose: true, body:
          '<div class="wfield"><span class="wfield-l"><span>Временный пароль</span><span class="wmicro">показывается один раз</span></span>' + secretBlock(pw) + '</div>' +
          W.kv([['Первый вход', 'сотрудник задаёт свой пароль по политике'], ['Журнал безопасности', 'событие «Создана учётная запись»']]) +
          W.note('Передайте пароль лично. Повторно показать его нельзя - только выдать новый.', { tone: 'warn', icon: 'alert' }),
          actions: W.btn('Готово', { kind: 'primary', attrs: 'data-done="1"' }) }), { replace: ov });
        bindCopy(done, pw);
        done.querySelector('[data-done]').addEventListener('click', function () { A.close(done); A.reload(); });
      }, function (err) { A.fail(err, 'Учётная запись не создана'); });
    });
  }

  function sessionsHtml(u, sess) {
    if (!u.is_active) return '<p class="wlabel">Сеансы закрыты при блокировке.</p>';
    if (!sess.length) return '<p class="wlabel">Открытых сеансов нет.</p>';
    return '<div class="wlist">' + sess.map(function (x) {
      var web = /веб|web|браузер/i.test(x.device || '');
      return '<div class="wli"><span class="wli-ic">' + icon(web ? 'globe' : 'phone', 16) + '</span><span class="wli-t"><b>' + esc(x.device || 'Устройство без названия') + '</b><span>с ' + esc(A.dt(x.started_at)) + ' · обновление ' + esc(A.dt(x.last_seen_at)) + '</span></span>' +
        W.btn('Закрыть', { kind: 'ghost', size: 'sm', attrs: 'data-sess-close="' + esc(x.id) + '"' }) + '</div>';
    }).join('') + '</div>';
  }

  /** Карточка сотрудника: сеансы, смена роли, сброс пароля, блокировка с причиной и разблокировка. */
  function userDrawer(id, replace) {
    Promise.all([A.get('/admin/users/' + id), A.get('/admin/users/' + id + '/sessions'), A.get('/webadmin/users/' + id + '/block').catch(function () { return {}; })]).then(function (d) {
      var u = d[0], sess = d[1], blk = d[2], st = status(u), s = ST[st], self = u.id === A.user.id;
      var note = st === 'temp' ? W.note('<b>Временный пароль.</b> Сотрудник ещё не сменил пароль. Если пароль утерян, выдайте новый.', { tone: 'warn', icon: 'key' })
        : st === 'blocked' ? W.note('<b>Заблокирована' + (blk.at ? ' ' + esc(A.dt(blk.at)) : '') + (blk.actor ? ' · ' + esc(blk.actor) : '') + '.</b> ' + (blk.reason ? 'Причина: ' + esc(blk.reason.toLowerCase()) + (blk.comment ? ' (' + esc(blk.comment) + ')' : '') + '. ' : '') + 'Вход и сеансы запрещены.', { tone: 'bad', icon: 'ban' }) : '';
      var foot = st === 'blocked' ? W.btn('Разблокировать', { kind: 'primary', icon: 'unlock', attrs: 'data-unblock="1"' })
        : W.btn('Сбросить пароль', { kind: 'secondary', icon: 'key', attrs: 'data-reset="1"' }) + W.btn('Заблокировать', { kind: 'danger-soft', icon: 'ban', disabled: self, title: self ? 'Нельзя заблокировать собственную учётную запись' : '', attrs: 'data-block="1"' });
      var html = W.drawer({ title: u.name, sub: u.email, lead: KV.avatar(u.name, 'lg'), chips: A.chip(s[0], s[1]) + W.tag(shortRole(u.role, u.role_title)) + (self ? W.tag('это вы', 'brand') : ''), body:
        note +
        '<div class="wdsec"><h3>Учётная запись</h3>' + W.kv([['Роль', esc(shortRole(u.role, u.role_title)) + (st === 'blocked' ? '' : ' · <button class="wlink" data-role="1">изменить</button>'), true], ['Создана', A.dt(u.created_at)], ['Последний вход', u.last_login_at ? A.dt(u.last_login_at) : 'ещё не входил'], ['Пароль изменён', u.password_changed_at ? A.dt(u.password_changed_at) : (u.must_change_password ? 'временный' : '—')]]) + '</div>' +
        '<div class="wdsec"><h3>Сеансы <span class="wmicro">' + (u.is_active ? sess.length : 0) + ' открыто</span></h3>' + sessionsHtml(u, sess) +
          (u.is_active && sess.length > 1 ? W.btn('Закрыть все сеансы', { kind: 'secondary', size: 'sm', icon: 'logout', attrs: 'data-sess-all="1"' }) : '') + '</div>' +
        (self ? W.note('Свою запись нельзя заблокировать, а свою роль нельзя сменить так, чтобы никто не смог управлять учётными записями.', { icon: 'shield' }) : ''),
        foot: '<span class="wgrow">Действия записываются в журнал безопасности</span>' + foot });
      var ov = A.open(html, { replace: replace });
      var again = function () { userDrawer(id, ov); };
      var changed = function () { again(); refreshList(); };
      Array.prototype.forEach.call(ov.querySelectorAll('[data-sess-close]'), function (b) {
        b.addEventListener('click', function () {
          A.busy(b, A.del('/admin/users/' + id + '/sessions/' + encodeURIComponent(b.getAttribute('data-sess-close')))).then(function () {
            A.toast('Сеанс закрыт', u.name + ': при следующем запросе на этом устройстве потребуется вход', 'ok'); changed();
          }, function (err) { A.fail(err); });
        });
      });
      var all = ov.querySelector('[data-sess-all]');
      if (all) all.addEventListener('click', function () {
        A.busy(all, A.del('/admin/users/' + id + '/sessions')).then(function (r) { A.toast('Сеансы закрыты', 'Закрыто: ' + r.revoked + '. Потребуется новый вход', 'ok'); changed(); }, function (err) { A.fail(err); });
      });
      var role = ov.querySelector('[data-role]');
      if (role) role.addEventListener('click', function () { roleModal(u, changed); });
      var reset = ov.querySelector('[data-reset]');
      if (reset) reset.addEventListener('click', function () { resetModal(u, changed); });
      var block = ov.querySelector('[data-block]');
      if (block && !self) block.addEventListener('click', function () { blockModal(u, sess.length, changed); });
      var unb = ov.querySelector('[data-unblock]');
      if (unb) unb.addEventListener('click', function () {
        var m = A.open(W.modal({ icon: 'unlock', title: 'Разблокировать ' + u.name + '?', text: 'Сотрудник сможет войти с прежним паролем. Если пароль мог стать известен другим, после разблокировки сбросьте его.', size: 's',
          actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Разблокировать', { kind: 'primary', icon: 'unlock', attrs: 'data-ok="1"' }) }));
        m.querySelector('[data-ok]').addEventListener('click', function (e) {
          A.busy(e.currentTarget, A.post('/admin/users/' + id + '/unblock')).then(function () { A.close(m); A.toast('Блокировка снята', u.name + ' снова может войти. Закрытые сеансы не восстанавливаются.', 'ok', 'unlock'); changed(); }, function (err) { A.fail(err); });
        });
      });
    }, function (err) { A.fail(err, 'Карточка не открылась'); });
  }
  function refreshList() { var c = A.current(); if (c && c.key === 'users') softReload(); }
  function softReload() {
    Promise.all([A.get('/admin/users'), A.get('/admin/roles')]).then(function (d) {
      var page = A.pages.users, main = A.root.querySelector('.wmain');
      if (!main || A.current().key !== 'users') return;
      var q = main.querySelector('[data-wfilter]'), qv = q ? q.value : '';
      var o = page.render(d);
      var inner = main.querySelector('.wmain-in');
      inner.innerHTML = o.body;
      W.typo(inner);
      var nq = inner.querySelector('[data-wfilter]'); if (nq) nq.value = qv;
      page.after(main);
    });
  }

  function roleModal(u, changed) {
    var m = A.open(W.modal({ icon: 'key', title: 'Роль: ' + u.name, text: 'Новые права действуют со следующего запроса сотрудника, без повторного входа.', size: 'm', body: '<div data-roles="1">' + roleRadios(u.role) + '</div>',
      actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Сохранить', { kind: 'primary', icon: 'check', attrs: 'data-ok="1"' }) }));
    m.querySelector('[data-ok]').addEventListener('click', function (e) {
      var code = picked(m, '[data-roles]');
      A.busy(e.currentTarget, A.post('/admin/users/' + u.id + '/role', { role: code })).then(function () {
        A.close(m); A.toast('Роль сохранена', u.name + ': изменение записано в журнал безопасности', 'ok', 'key'); changed();
      }, function (err) { if (isGuard(err)) { A.close(m); guardModal(err.detail); } else A.fail(err, 'Роль не изменена'); });
    });
  }
  function resetModal(u, changed) {
    var m = A.open(W.modal({ icon: 'key', tone: 'warn', title: 'Сбросить пароль?', text: u.name + ' получит новый временный пароль. Все открытые сеансы сотрудника закроются сразу.', size: 's',
      actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Сбросить', { kind: 'primary', icon: 'key', attrs: 'data-ok="1"' }) }));
    m.querySelector('[data-ok]').addEventListener('click', function (e) {
      A.busy(e.currentTarget, A.post('/admin/users/' + u.id + '/reset-password')).then(function (r) {
        var done = A.open(W.modal({ icon: 'checkCircle', tone: 'ok', title: 'Пароль сброшен', text: u.name + ' · ' + u.email, size: 's', noClose: true, body:
          secretBlock(r.temporary_password) + W.kv([['Сеансы', 'закрыты'], ['Первый вход', 'сотрудник задаёт свой пароль']]) + W.note('Передайте пароль лично, он показывается один раз.', { tone: 'warn', icon: 'alert' }),
          actions: W.btn('Готово', { kind: 'primary', close: true }) }), { replace: m });
        bindCopy(done, r.temporary_password);
        changed();
      }, function (err) { A.fail(err, 'Пароль не сброшен'); });
    });
  }
  function blockModal(u, n, changed) {
    var m = A.open(W.modal({ icon: 'ban', tone: 'bad', title: 'Заблокировать ' + u.name + '?', text: 'Вход будет запрещён, все сеансы закроются сразу (' + n + '). Данные осмотров сохранятся.', size: 'm', body:
      '<div class="wfield" data-reasons="1"><span class="wfield-l"><span>Причина</span><span class="wmicro">видна в журнале безопасности</span></span>' + W.filters(REASONS.map(function (r) { return { label: r, key: r }; })) + '</div>' +
      W.field({ label: 'Комментарий', area: true, name: 'comment', placeholder: 'Необязательно' }),
      actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Заблокировать', { kind: 'danger', icon: 'ban', attrs: 'data-ok="1"' }) }));
    m.querySelector('[data-ok]').addEventListener('click', function (e) {
      var on = m.querySelector('[data-reasons] .wf.is-on');
      if (!on) { A.toast('Укажите причину', 'Причина блокировки записывается в журнал безопасности', 'warn'); return; }
      var comment = m.querySelector('[name=comment]').value.trim();
      A.busy(e.currentTarget, A.post('/webadmin/users/' + u.id + '/block', { reason: on.getAttribute('data-key'), comment: comment || null })).then(function () {
        A.close(m); A.toast('Учётная запись заблокирована', u.name + ': сеансы закрыты, событие в журнале безопасности', 'ok', 'ban'); changed();
      }, function (err) { if (isGuard(err)) { A.close(m); guardModal(err.detail); } else A.fail(err, 'Блокировка не выполнена'); });
    });
  }

  /* ---------- Роли и права ---------- */
  A.page('roles', { title: 'Роли и права', guard: function () { return A.can('roles.manage') || A.can('users.manage'); },
    load: function () { return Promise.all([A.get('/admin/roles'), A.get('/admin/permissions'), A.can('users.manage') ? A.get('/admin/users') : Promise.resolve(null)]); },
    render: function (d) {
      var roles = d[0], groups = d[1], edit = A.can('roles.manage');
      cache.roles = roles; cache.groups = groups; cache.users = d[2] || cache.users;
      var nPerm = groups.reduce(function (s, g) { return s + g.permissions.length; }, 0);
      var head = '<tr><th>Право</th>' + roles.map(function (r) {
        return '<th><button class="rh" data-role-open="' + esc(r.code) + '"><b>' + esc(shortRole(r.code, r.title)) + '</b><small>' + (r.is_system ? icon('lock', 12) + 'системная' : 'своя') + '</small><small>' + r.members + ' сотр.</small></button></th>';
      }).join('') + '</tr>';
      var body = groups.map(function (g) {
        return '<tr class="g"><td colspan="' + (roles.length + 1) + '">' + esc(g.title) + '</td></tr>' + g.permissions.map(function (p) {
          return '<tr><td><b>' + esc(p.title) + (GUARD.indexOf(p.code) >= 0 ? '<span class="guard" title="Хотя бы у одного активного сотрудника">' + icon('shield', 14) + '</span>' : '') + '</b><small>' + esc(p.code) + '</small></td>' + roles.map(function (r) {
            var on = r.permissions.indexOf(p.code) >= 0;
            return '<td>' + W.check(on, { locked: !edit, attrs: 'data-r="' + esc(r.code) + '" data-p="' + esc(p.code) + '" data-orig="' + (on ? 1 : 0) + '" title="' + esc(p.description) + '" aria-label="' + esc(r.title + ': ' + p.title) + '"' }) + '</td>';
          }).join('') + '</tr>';
        }).join('');
      }).join('');
      return { title: 'Роли и права', sub: roles.length + ' ролей · ' + nPerm + ' прав · сервер проверяет права на каждом запросе',
        actions: edit ? W.btn('Создать роль', { kind: 'primary', icon: 'plus', attrs: 'data-new-role="1"' }) : '',
        body: W.note('Права зашиты в сервер, роли - данные: права системных ролей можно менять, удалить можно только свою роль без сотрудников. Значок ' + icon('shield', 14).replace('class="ic"', 'class="ic" style="display:inline;vertical-align:-2px"') + ' - право, которое должно остаться хотя бы у одного активного сотрудника.' + (edit ? '' : ' Изменять права может только роль с правом «Управление ролями».'), { icon: 'info' }) +
          '<div class="wtbl-wrap" style="overflow:visible"><table class="wmx"><colgroup><col class="c-perm">' + roles.map(function () { return '<col class="c-role">'; }).join('') + '</colgroup><thead>' + head + '</thead><tbody>' + body + '</tbody></table></div>',
        banner: edit ? '<div class="wdirty" data-dirty="1"><i class="dot warn"></i><div class="wgrow"><b data-dirty-t="1">Несохранённые изменения</b><span data-dirty-s="1"></span></div>' +
          W.btn('Отменить', { kind: 'ghost', size: 'sm', attrs: 'data-dirty-undo="1"' }) + W.btn('Сохранить', { kind: 'primary', size: 'sm', icon: 'check', attrs: 'data-dirty-save="1"' }) + '</div>' : '' };
    },
    after: function (main, d) {
      var roles = d[0], groups = d[1];
      var title = {}; groups.forEach(function (g) { g.permissions.forEach(function (p) { title[p.code] = p.title; }); });
      var rname = {}; roles.forEach(function (r) { rname[r.code] = shortRole(r.code, r.title); });
      Array.prototype.forEach.call(main.querySelectorAll('[data-role-open]'), function (b) { b.addEventListener('click', function () { roleDrawer(b.getAttribute('data-role-open')); }); });
      var nr = main.querySelector('[data-new-role]'); if (nr) nr.addEventListener('click', newRole);
      var bar = main.querySelector('[data-dirty]');
      if (!bar) return;
      var checks = Array.prototype.slice.call(main.querySelectorAll('.wcheck[data-p]'));
      var diff = function () {
        var out = [];
        checks.forEach(function (c) {
          var on = c.classList.contains('is-on'), orig = c.getAttribute('data-orig') === '1';
          c.classList.toggle('is-changed', on !== orig);
          if (on !== orig) out.push([c.getAttribute('data-r'), c.getAttribute('data-p'), on]);
        });
        return out;
      };
      var render = function () {
        var df = diff();
        bar.classList.toggle('is-on', df.length > 0);
        bar.querySelector('[data-dirty-t]').textContent = 'Несохранённые изменения: ' + df.length;
        bar.querySelector('[data-dirty-s]').textContent = df.slice(0, 3).map(function (x) { return rname[x[0]] + ': ' + (x[2] ? '+ ' : '− ') + (title[x[1]] || x[1]).toLowerCase(); }).join(' · ') + (df.length > 3 ? ' · ещё ' + (df.length - 3) : '');
        return df;
      };
      var undo = function () { checks.forEach(function (c) { var o = c.getAttribute('data-orig') === '1'; c.classList.toggle('is-on', o); c.setAttribute('aria-checked', o ? 'true' : 'false'); }); render(); };
      main.addEventListener('click', function (e) { if (e.target.closest('.wcheck[data-p]')) setTimeout(render, 0); });
      bar.querySelector('[data-dirty-undo]').addEventListener('click', undo);
      bar.querySelector('[data-dirty-save]').addEventListener('click', function (e) {
        var df = render();
        if (!df.length) return;
        var codes = [];
        df.forEach(function (x) { if (codes.indexOf(x[0]) < 0) codes.push(x[0]); });
        var chain = Promise.resolve(), saved = 0;
        codes.forEach(function (code) {
          chain = chain.then(function () {
            var perms = checks.filter(function (c) { return c.getAttribute('data-r') === code && c.classList.contains('is-on'); }).map(function (c) { return c.getAttribute('data-p'); });
            return A.patch('/admin/roles/' + encodeURIComponent(code), { permissions: perms }).then(function () {
              saved++;
              checks.forEach(function (c) { if (c.getAttribute('data-r') === code) c.setAttribute('data-orig', c.classList.contains('is-on') ? '1' : '0'); });
            });
          });
        });
        A.busy(e.currentTarget, chain).then(function () {
          render();
          A.toast('Права сохранены', 'Ролей изменено: ' + saved + '. Действуют со следующего запроса сотрудников. Событие «Изменена роль» в журнале.', 'ok', 'key');
        }, function (err) {
          render();
          if (isGuard(err)) guardModal(err.detail, undo);
          else A.fail(err, 'Права не сохранены');
        });
      });
      render();
    } });

  function newRole() {
    var ov = A.open(W.modal({ icon: 'plus', title: 'Новая роль', text: 'Роль появится столбцом в таблице прав. Права можно поправить сразу после создания.', size: 'm', body:
      '<div class="wform-2">' + W.field({ label: 'Название', name: 'title', placeholder: 'Наблюдатель', attrs: 'data-autofocus="1"' }) + W.field({ label: 'Код', name: 'code', mono: true, placeholder: 'observer', help: 'Латиница, цифры и _, не меняется' }) + '</div>' +
      W.field({ label: 'Описание', name: 'description', area: true, placeholder: 'Что делает сотрудник с этой ролью' }) +
      '<div class="wfield" data-copy-from="1"><span class="wfield-l"><span>Скопировать права</span></span>' + W.radios([{ title: 'Не копировать', sub: 'Роль без прав', key: '', on: true }].concat(cache.roles.map(function (r) { return { title: shortRole(r.code, r.title), sub: r.permissions.length + ' прав', key: r.code }; }))) + '</div>',
      actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Создать', { kind: 'primary', icon: 'check', attrs: 'data-ok="1"' }) }));
    ov.querySelector('[data-ok]').addEventListener('click', function (e) {
      var body = { title: ov.querySelector('[name=title]').value.trim(), code: ov.querySelector('[name=code]').value.trim(), description: ov.querySelector('[name=description]').value.trim() };
      var from = picked(ov, '[data-copy-from]');
      if (from) body.copy_from = from;
      if (!body.title || !body.code) { A.toast('Заполните поля', 'Укажите название и код роли', 'warn'); return; }
      if (!/^[a-z][a-z0-9_]{1,31}$/.test(body.code)) { A.toast('Код роли не подходит', 'Код: латиница в нижнем регистре, цифры и _, от 2 до 32 символов, начинается с буквы', 'warn'); return; }
      A.busy(e.currentTarget, A.post('/admin/roles', body)).then(function (r) {
        A.close(ov); A.toast('Роль «' + r.title + '» создана', (r.permissions.length ? 'Скопировано прав: ' + r.permissions.length + '. ' : '') + 'Назначьте роль в карточке сотрудника.', 'ok', 'key'); A.reload();
      }, function (err) { A.fail(err, 'Роль не создана'); });
    });
  }

  function roleDrawer(code) {
    var r = cache.roles.filter(function (x) { return x.code === code; })[0];
    if (!r) return;
    var edit = A.can('roles.manage');
    var by = {};
    (cache.groups || []).forEach(function (g) { g.permissions.forEach(function (p) { if (r.permissions.indexOf(p.code) >= 0) (by[g.title] = by[g.title] || []).push(p.title); }); });
    var members = (cache.users || []).filter(function (u) { return u.role === code; });
    var ov = A.open(W.drawer({ title: shortRole(r.code, r.title), sub: r.title + ' · код ' + r.code, chips: (r.is_system ? W.tag('системная') : W.tag('своя роль', 'brand')) + W.tag(r.permissions.length + ' прав') + W.tag(r.members + ' сотр.'), body:
      (r.is_system ? W.note('Системную роль удалить нельзя. Название и права можно менять; изменения проверяет сервер.', { icon: 'lock' }) : '') +
      '<div class="wform">' + W.field({ label: 'Название', name: 'title', value: r.title, ro: !edit }) + W.field({ label: 'Описание', name: 'description', value: r.description, area: true }) + '</div>' +
      '<div class="wdsec"><h3>Права</h3>' + (Object.keys(by).length ? W.kv(Object.keys(by).map(function (g) { return [g, by[g].join(', ')]; })) : '<p class="wlabel">У роли нет прав.</p>') + '</div>' +
      '<div class="wdsec"><h3>Сотрудники <span class="wmicro">' + r.members + '</span></h3>' + (members.length ? '<div class="wlist">' + members.map(function (m) {
        var s = ST[status(m)];
        return '<div class="wli">' + KV.avatar(m.name, 'sm') + '<span class="wli-t"><b>' + esc(m.name) + '</b><span>' + esc(m.email) + '</span></span><span class="wli-r">' + A.chip(s[0], s[1]) + '</span></div>'; }).join('') + '</div>'
        : '<p class="wlabel">' + (r.members ? 'Список сотрудников доступен с правом «Управление учётными записями».' : 'Роль пока никому не назначена.') + '</p>') + '</div>',
      foot: '<span class="wgrow">' + (r.is_system ? 'Создана при установке сервера' : 'Создана ' + A.dt(r.created_at)) + '</span>' +
        (edit && !r.is_system ? W.btn('Удалить', { kind: 'danger-soft', icon: 'trash', attrs: 'data-del="1"' }) : '') + (edit ? W.btn('Сохранить', { kind: 'primary', icon: 'check', attrs: 'data-save="1"' }) : '') }));
    var save = ov.querySelector('[data-save]');
    if (save) save.addEventListener('click', function () {
      A.busy(save, A.patch('/admin/roles/' + encodeURIComponent(code), { title: ov.querySelector('[name=title]').value.trim(), description: ov.querySelector('[name=description]').value.trim() })).then(function (x) {
        A.close(ov); A.toast('Роль «' + x.title + '» сохранена', 'Название и описание обновлены, событие в журнале безопасности.', 'ok', 'key'); A.reload();
      }, function (err) { A.fail(err, 'Роль не сохранена'); });
    });
    var del = ov.querySelector('[data-del]');
    if (del) del.addEventListener('click', function () {
      var m = A.open(W.modal({ icon: 'trash', tone: 'bad', title: 'Удалить роль «' + r.title + '»?', text: r.members ? 'Роль назначена сотрудникам (' + r.members + '): сервер откажет, пока им не сменят роль.' : 'Роль никому не назначена, её можно удалить.', size: 's',
        actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Удалить', { kind: 'danger', icon: 'trash', attrs: 'data-ok="1"' }) }));
      m.querySelector('[data-ok]').addEventListener('click', function (e) {
        A.busy(e.currentTarget, A.del('/admin/roles/' + encodeURIComponent(code))).then(function () { A.closeAll(); A.toast('Роль удалена', '«' + r.title + '» удалена. Событие в журнале безопасности.', 'ok', 'trash'); A.reload(); },
          function (err) { A.close(m); A.fail(err, 'Роль не удалена'); });
      });
    });
  }

  /* ---------- Журнал безопасности ---------- */
  var EV = { login_success: ['ok', 'in'], login_biometric: ['ok', 'in'], login_failure: ['warn', 'fail'], login_locked: ['bad', 'fail'], login_blocked: ['bad', 'fail'], password_change_failed: ['warn', 'fail'],
    password_changed: ['info', 'acc'], password_reset: ['info', 'acc'], user_created: ['info', 'acc'], user_blocked: ['bad', 'acc'], user_unblocked: ['info', 'acc'], user_role_changed: ['info', 'acc'], sessions_revoked: ['info', 'acc'],
    role_created: ['info', 'role'], role_updated: ['info', 'role'], role_deleted: ['info', 'role'], policy_changed: ['info', 'role'] };
  function who(p) { return p ? p.name : '—'; }
  function detailsText(d) {
    return Object.keys(d || {}).map(function (k) { var v = d[k]; return k + ': ' + (Array.isArray(v) ? v.join(' → ') : typeof v === 'object' && v ? JSON.stringify(v) : v); }).join(' · ');
  }
  A.page('seclog', { title: 'Журнал безопасности', guard: function () { return A.can('security.log'); },
    load: function () { return A.get('/admin/security-log?limit=1000'); },
    render: function (rows) {
      var now = Date.now(), day = 86400000;
      var start = new Date(); start.setHours(0, 0, 0, 0);
      var c = { today: 0, week: 0, fail: 0, logins: 0, rights: 0 };
      var trs = rows.map(function (l, n) {
        var ev = EV[l.event] || ['info', 'acc'], t = new Date(l.at).getTime();
        var per = (t >= start.getTime() ? 'today week' : t >= now - 7 * day ? 'week' : '') + ' month';
        if (t >= start.getTime()) { c.today++; if (l.event === 'login_success' || l.event === 'login_biometric') c.logins++; if (ev[1] === 'fail') c.fail++; }
        if (t >= now - 7 * day) c.week++;
        if (ev[1] === 'role') c.rights++;
        var account = l.target_user ? l.target_user.email : l.target_role ? 'роль ' + l.target_role : l.email || '—';
        return { key: ev[1] + ' ' + per, text: [l.title, account, who(l.actor), l.ip, detailsText(l.details)].join(' '), log: n,
          cells: ['<span class="wmono">' + esc(A.dt(l.at, { sec: true })) + '</span>', '<div class="wcell"><div><span class="t-main"><span class="wlevel"><i class="dot ' + ev[0] + '"></i>' + esc(l.title) + '</span></span><span class="t-sub">' + esc(detailsText(l.details) || l.event) + '</span></div></div>',
            esc(account), esc(who(l.actor)), '<span class="wmono">' + esc(l.ip || '—') + '</span>', icon('chevronRight', 18)] };
      });
      var html = W.table([{ label: 'Время', cls: 'nw' }, { label: 'Событие' }, { label: 'Учётная запись' }, { label: 'Выполнил' }, { label: 'Адрес' }, { label: '', cls: 'chev' }], trs, { dense: true,
        empty: W.empty({ icon: 'search', title: 'Событий не найдено', text: 'Измените период, тип события или текст поиска.' }) });
      var k = 0;
      html = html.replace(/<tr class="" {2}data-key/g, function () { return '<tr class="" data-log="' + (k++) + '" role="button" tabindex="0" data-key'; });
      return { title: 'Журнал безопасности', sub: 'Входы, блокировки, изменения учётных записей, ролей и политики · GET /admin/security-log',
        actions: W.btn('Выгрузить CSV', { kind: 'secondary', icon: 'download', attrs: 'data-csv="1"' }),
        body: W.kpis([{ label: 'Входов сегодня', icon: 'logout', value: String(c.logins), note: 'успешные входы' }, { label: 'Неудачные сегодня', icon: 'alert', value: String(c.fail), status: c.fail ? 'warn' : '', note: 'попытки входа и смены пароля' },
          { label: 'Событий за 7 дней', icon: 'list', value: String(c.week), note: 'всего в выборке ' + rows.length }, { label: 'Изменения ролей и политики', icon: 'key', value: String(c.rights), note: 'за всё время выборки' }]) +
          '<div class="wcol"><div class="wtoolbar">' + W.search('Почта, адрес или текст') + W.filters([{ label: 'Сегодня', count: c.today, key: 'today' }, { label: '7 дней', count: c.week, key: 'week' }, { label: 'Все', count: rows.length, key: '', on: true }], { group: 'per' }) + '</div>' +
          W.filters([{ label: 'Все события', key: '', on: true }, { label: 'Входы', key: 'in', dot: 'ok' }, { label: 'Неудачные', key: 'fail', dot: 'bad' }, { label: 'Учётные записи', key: 'acc', dot: 'info' }, { label: 'Роли и политика', key: 'role', dot: 'info' }], { group: 'ev' }) + '</div>' + html };
    },
    after: function (main, rows) {
      W.bindFilter(main, {});
      Array.prototype.forEach.call(main.querySelectorAll('[data-log]'), function (tr) {
        tr.addEventListener('click', function () {
          var l = rows[+tr.getAttribute('data-log')], ev = EV[l.event] || ['info'];
          var det = Object.keys(l.details || {}).map(function (k) { var v = l.details[k]; return [k, Array.isArray(v) ? v.join(' → ') : typeof v === 'object' && v ? JSON.stringify(v) : String(v)]; });
          A.open(W.drawer({ title: l.title, sub: A.dt(l.at, { sec: true }) + (l.ip ? ' · ' + l.ip : ''), chips: '<span class="wlevel"><i class="dot ' + ev[0] + '"></i>' + esc(l.event) + '</span>', body:
            '<div class="wdsec"><h3>Событие</h3>' + W.kv([['Код', '<span class="wmono">' + esc(l.event) + '</span>', true], ['Время', A.dt(l.at, { sec: true })], ['Учётная запись', l.target_user ? l.target_user.name + ' · ' + l.target_user.email : (l.email || '—')], ['Роль', l.target_role || '—'], ['Выполнил', l.actor ? l.actor.name + ' · ' + l.actor.email : '—'], ['Адрес', l.ip || '—']]) + '</div>' +
            '<div class="wdsec"><h3>Подробности</h3>' + (det.length ? W.kv(det) : '<p class="wlabel">Без подробностей.</p>') + '</div>',
            foot: '<span class="wgrow">Запись журнала не изменяется</span>' + W.btn('Закрыть', { kind: 'primary', close: true }) }));
        });
      });
      main.querySelector('[data-csv]').addEventListener('click', function () {
        var q = function (s) { return '"' + String(s == null ? '' : s).replace(/"/g, '""') + '"'; };
        var lines = [['время', 'событие', 'код', 'учётная запись', 'выполнил', 'адрес', 'подробности'].map(q).join(';')].concat(rows.map(function (l) {
          return [l.at, l.title, l.event, l.target_user ? l.target_user.email : (l.target_role || l.email || ''), l.actor ? l.actor.email : '', l.ip || '', detailsText(l.details)].map(q).join(';');
        }));
        var blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
        var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'security-log_' + A.isoLocal(new Date()).slice(0, 10) + '.csv';
        document.body.appendChild(a); a.click(); setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 500);
        A.toast('Журнал выгружен', a.download + ' · событий: ' + rows.length, 'ok', 'download');
      });
    } });

  /* ---------- Политика ---------- */
  var POL_LABEL = { min_password_length: ['Минимальная длина пароля', 'символов'], lockout_attempts: ['Неудачных попыток до закрытия входа', ''], lockout_minutes: ['Окно подсчёта попыток', 'мин'], session_hours: ['Срок сеанса', 'ч'] };
  A.page('policy', { title: 'Политика безопасности', guard: function () { return A.can('security.policy'); },
    load: function () { return A.get('/admin/policy'); },
    render: function (v) {
      var row = function (title, sub, ctl) { return '<div class="wpol"><div class="wpol-t"><b>' + title + '</b><span>' + sub + '</span></div><div class="wpol-c">' + ctl + '</div></div>'; };
      var step = function (k, o) { return W.stepper(v[k], Object.assign({ key: k, suffix: POL_LABEL[k][1] }, o)); };
      return { title: 'Политика безопасности', sub: 'Читается при каждом входе: изменения действуют сразу · сервер проверяет допустимые пределы',
        body: '<div class="wgrid wg-side"><div class="wcol l">' +
          W.panel({ title: 'Пароли', body: row('Минимальная длина', 'От 6 до 128 символов. Временные пароли сервер делает не короче 12 символов', step('min_password_length', { min: 6, max: 128 })) +
            row('Буквы и цифры обязательны', 'Пароль из одних цифр или одних букв не примется', W.sw(v.require_letters_digits, { label: 'Буквы и цифры', attrs: 'data-pol="require_letters_digits" data-orig="' + (v.require_letters_digits ? 1 : 0) + '"' })) +
            row('Пробелы в начале и в конце', 'Запрещены всегда, настройка не меняется', W.sw(true, { locked: true, label: 'Пробелы запрещены' })) }) +
          W.panel({ title: 'Блокировка входа', sub: 'Считается по паре почта + адрес устройства', body: row('Неудачных попыток', 'От 3 до 100. После превышения вход закрывается до конца окна', step('lockout_attempts', { min: 3, max: 100 })) +
            row('Окно подсчёта', 'От 1 до 1 440 мин. Сервер отвечает «повторите через N с»', step('lockout_minutes', { min: 1, max: 1440 })) }) +
          W.panel({ title: 'Сеансы и биометрия', body: row('Срок сеанса', 'От 1 до 8 760 ч, затем вход заново. Токен доступа живёт 30 мин и обновляется сам', step('session_hours', { min: 1, max: 8760, inc: 24 })) +
            row('Вход по биометрии на телефоне', 'Если выключить, телефоны попросят пароль при следующем входе', W.sw(v.biometrics_allowed, { label: 'Биометрия', attrs: 'data-pol="biometrics_allowed" data-orig="' + (v.biometrics_allowed ? 1 : 0) + '"' })) }) +
        '</div><div class="wcol l">' +
          W.panel({ title: 'Сейчас действует', sub: 'GET /admin/policy', body: W.kv([['Пароль', 'от ' + v.min_password_length + ' символов' + (v.require_letters_digits ? ', буквы и цифры' : '')], ['Блокировка', v.lockout_attempts + ' попыток за ' + v.lockout_minutes + ' мин'], ['Сеанс', num(v.session_hours) + ' ч'], ['Биометрия', v.biometrics_allowed ? 'разрешена' : 'запрещена'], ['Изменено', v.updated_at ? A.dt(v.updated_at) : 'значения по умолчанию']]) }) +
          W.panel({ cls: 'quiet', title: 'Защита от потери управления', body: '<p class="wlabel">Сервер не сохранит изменение ролей или учётных записей, после которого никто не сможет управлять учётными записями и ролями. Ответ 409 с объяснением.</p>' }) +
          '<div class="wpanel" data-pol-bar="1"><span class="wlabel" data-pol-n="1">Изменений нет</span><div class="wrow">' + W.btn('Сохранить', { kind: 'primary', icon: 'check', attrs: 'data-pol-save="1"' }) +
            W.btn('Отменить', { kind: 'ghost', attrs: 'data-pol-undo="1"' }) + '</div></div>' +
        '</div></div>' };
    },
    after: function (main) {
      var bar = main.querySelector('[data-pol-bar]'), save = bar.querySelector('[data-pol-save]'), lab = bar.querySelector('[data-pol-n]');
      var val = function (s) { return +s.querySelector('output').textContent.replace(/\s/g, ''); };
      var diff = function () {
        var out = [], body = {};
        Array.prototype.forEach.call(main.querySelectorAll('.wstep[data-step]'), function (s) {
          var k = s.getAttribute('data-step'), cur = val(s), o = +s.getAttribute('data-orig');
          s.classList.toggle('is-changed', cur !== o);
          if (cur !== o) { out.push([POL_LABEL[k][0], num(o) + (POL_LABEL[k][1] ? ' ' + POL_LABEL[k][1] : ''), num(cur) + (POL_LABEL[k][1] ? ' ' + POL_LABEL[k][1] : '')]); body[k] = cur; }
        });
        Array.prototype.forEach.call(main.querySelectorAll('[data-pol]'), function (s) {
          var on = s.classList.contains('is-on'), o = s.getAttribute('data-orig') === '1';
          if (on !== o) { out.push([s.getAttribute('data-pol') === 'biometrics_allowed' ? 'Вход по биометрии' : 'Буквы и цифры обязательны', o ? 'да' : 'нет', on ? 'да' : 'нет']); body[s.getAttribute('data-pol')] = on; }
        });
        return { list: out, body: body };
      };
      var upd = function () { var d = diff(); lab.textContent = d.list.length ? 'Изменений: ' + d.list.length : 'Изменений нет'; save.disabled = !d.list.length; };
      main.addEventListener('click', function (e) {
        var b = e.target.closest('.wstep button');
        if (b) {
          var s = b.closest('.wstep'), out = s.querySelector('output'), inc = +s.getAttribute('data-inc') * +b.getAttribute('data-d');
          var v = Math.max(+s.getAttribute('data-min'), Math.min(+s.getAttribute('data-max'), val(s) + inc));
          out.textContent = num(v); upd(); return;
        }
        if (e.target.closest('[data-pol]')) setTimeout(upd, 0);
      });
      bar.querySelector('[data-pol-undo]').addEventListener('click', function () {
        Array.prototype.forEach.call(main.querySelectorAll('.wstep[data-step]'), function (s) { s.querySelector('output').textContent = num(+s.getAttribute('data-orig')); });
        Array.prototype.forEach.call(main.querySelectorAll('[data-pol]'), function (s) { var o = s.getAttribute('data-orig') === '1'; s.classList.toggle('is-on', o); s.setAttribute('aria-checked', o ? 'true' : 'false'); });
        upd();
      });
      save.addEventListener('click', function () {
        var d = diff();
        if (!d.list.length) return;
        var m = A.open(W.modal({ icon: 'shield', title: 'Сохранить политику безопасности?', text: 'Сервер применит изменения сразу: блокировка и срок сеанса - для новых входов, требования к паролю - при следующей смене пароля.', size: 'm', body:
          '<div class="wtbl-wrap"><table class="wtbl dense"><thead><tr><th>Параметр</th><th>Было</th><th>Станет</th></tr></thead><tbody>' + d.list.map(function (x) { return '<tr><td>' + esc(x[0]) + '</td><td>' + esc(x[1]) + '</td><td><b>' + esc(x[2]) + '</b></td></tr>'; }).join('') + '</tbody></table></div>' +
          W.note('Изменение запишется в журнал безопасности как «Изменена политика безопасности».', { icon: 'info' }),
          actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Сохранить', { kind: 'primary', icon: 'check', attrs: 'data-ok="1"' }) }));
        m.querySelector('[data-ok]').addEventListener('click', function (e) {
          A.busy(e.currentTarget, A.patch('/admin/policy', d.body)).then(function () {
            A.close(m); A.toast('Политика сохранена', 'Изменений: ' + d.list.length + '. Событие в журнале безопасности.', 'ok', 'shield'); A.reload();
          }, function (err) { A.fail(err, 'Политика не сохранена'); });
        });
      });
      upd();
    } });
})();
