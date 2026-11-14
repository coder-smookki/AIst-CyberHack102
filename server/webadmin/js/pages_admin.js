/**
 * Страницы администратора системы: обзор сервера, реестр оборудования, телеметрия и сценарии с курсором времени,
 * модели распознавания, журнал событий и резервные копии. Данные: /system/status, /health, /webadmin/*, /equipment.
 */
(function () {
  'use strict';
  var KV = window.KV, W = KV.w, A = window.WA, esc = KV.esc, icon = KV.icon, num = KV.num;
  var timers = [];
  A.stopTimers = function () { timers.forEach(function (t) { clearInterval(t); clearTimeout(t); }); timers = []; };
  var samples = [];
  var bench = null;
  var MODE = { running: ['В работе', 'ok'], stopped: ['Остановлен', 'unk'], repair: ['На ремонте', 'warn'] };
  var FSTATUS = { defect: 'bad', check: 'warn', unknown: 'unk', ok: 'ok' };

  function modeChip(m) { var x = MODE[m] || [m, 'unk']; return A.chip(x[0], x[1]); }
  function pct(a, b) { return a != null && b ? Math.round(a / b * 100) : null; }

  /* ---------- Обзор системы ---------- */
  function overviewLoad() {
    var soft = function (p) { return p.catch(function () { return null; }); };
    return Promise.all([A.get('/system/status'), A.get('/health'), soft(A.get('/webadmin/metrics')), A.get('/equipment'), soft(A.get('/webadmin/events?limit=6'))]).then(function (d) {
      var tele = d[3].filter(function (u) { return u.telemetry; });
      return Promise.all(tele.map(function (u) {
        return Promise.all([soft(A.get('/equipment/' + encodeURIComponent(u.id) + '/diagnosis')), soft(A.get('/equipment/' + encodeURIComponent(u.id) + '/telemetry'))]).then(function (x) { return { unit: u, diag: x[0], tel: x[1] }; });
      })).then(function (diags) { return { status: d[0], health: d[1], metrics: d[2], equipment: d[3], events: d[4] || [], diags: diags }; });
    });
  }
  function alarmsOf(diags) {
    var out = [];
    diags.forEach(function (x) {
      if (x.tel && x.tel.parameters) x.tel.parameters.forEach(function (p) {
        if (p.level === 'warn' || p.level === 'alarm') out.push({ tone: p.level === 'alarm' ? 'bad' : 'warn', icon: 'wave', title: x.unit.id + ' · ' + p.name + ' ' + num(p.value, p.value < 10 ? 2 : 0) + ' ' + (p.unit || ''), text: (p.level === 'alarm' ? 'Уставка тревоги ' + num(p.alarm) : 'Уставка предупреждения ' + num(p.warn)) + ' ' + (p.unit || '') + ' · ' + (p.source === 'model' ? 'модель' : 'база заказчика') });
      });
      if (x.diag) x.diag.findings.forEach(function (f) {
        if (f.status === 'defect' || f.status === 'check') out.push({ tone: FSTATUS[f.status], icon: f.status === 'defect' ? 'alert' : 'alertCircle', title: x.unit.id + ' · ' + f.rule_id + ' · ' + f.title, text: (f.node_name || '') + (f.severity_title ? ' · ' + f.severity_title : '') });
      });
    });
    return out;
  }
  function cpuChart() {
    if (samples.length < 2) return '<div class="wempty" style="padding:28px 12px"><p>Загрузка процессора сохраняется каждые 10 с, пока страница открыта. График появится после второго замера.</p></div>';
    var vals = samples.map(function (s) { return s.v; });
    var first = samples[0].t, last = samples[samples.length - 1].t;
    return W.chart({ values: vals, min: 0, max: 100, warn: 70, alarm: 90, unit: '%', grid: [25, 50, 75, 100], height: 200,
      axis: [A.dt(first, { time: true, sec: true }), A.dt(last, { time: true, sec: true })], tipText: function (k) { return [num(vals[k], 0) + ' %', A.dt(samples[k].t, { time: true, sec: true })]; },
      legend: [['var(--chart-ok)', 'норма'], ['var(--chart-warn)', 'выше 70 %'], ['var(--chart-alarm)', 'выше 90 %']] });
  }
  function cpuChartOpts() {
    var vals = samples.map(function (s) { return s.v; });
    return { values: vals, min: 0, max: 100, warn: 70, alarm: 90, height: 200, tipText: function (k) { return [num(vals[k], 0) + ' %', A.dt(samples[k].t, { time: true, sec: true })]; } };
  }
  function note(m) { if (m && m.cpu && m.cpu.percent != null) { samples.push({ t: m.time, v: m.cpu.percent }); if (samples.length > 120) samples.shift(); } }

  A.page('overview', { title: 'Обзор системы', guard: function () { return A.isAdmin(); },
    load: overviewLoad,
    render: function (d) {
      var s = d.status, h = d.health, m = d.metrics, det = s.detector || h.detector || {};
      note(m);
      var alarms = alarmsOf(d.diags);
      var models = det.models || [];
      var memPct = m && m.memory ? pct(m.memory.process_peak_bytes, m.memory.total_bytes) : null;
      var diskPct = m && m.disk ? pct(m.disk.used_bytes, m.disk.total_bytes) : null;
      var units = d.equipment.map(function (u) {
        var dg = d.diags.filter(function (x) { return x.unit.id === u.id; })[0];
        var tone = dg && dg.diag ? (dg.diag.status === 'defect' ? 'bad' : dg.diag.status === 'check' ? 'warn' : 'ok') : (u.open_findings ? 'warn' : '');
        return W.li({ tone: tone, icon: 'box', titleHtml: esc(u.id) + ' · ' + esc(MODE[u.mode] ? MODE[u.mode][0] : u.mode), text: u.name + (u.open_findings ? ' · открытых замечаний: ' + u.open_findings : '') + (u.telemetry ? ' · телеметрия' : ''), right: num(u.run_hours, 0) + ' ч' });
      }).join('');
      var alarmHtml = alarms.length ? alarms.slice(0, 5).map(function (a) { return W.li(a); }).join('') : '<p class="wlabel" style="padding:8px 4px">Активных тревог нет по текущему моменту ленты телеметрии.</p>';
      var modelHtml = models.map(function (f) { return W.li({ tone: det.loaded ? 'ok' : 'warn', icon: 'cpu', title: f, text: det.loaded ? 'Загружена' : (det.ready ? 'Загружается в фоне' : 'Не готова') }); }).join('') +
        (det.missing && det.missing.length ? W.li({ tone: 'bad', icon: 'alert', title: 'Нет файлов моделей', text: det.missing.join(', ') }) : '') +
        (det.note ? W.li({ tone: 'warn', icon: 'info', title: 'Примечание', text: det.note }) : '');
      var kv = [['Адрес', location.host], ['Ответ /health', h.ok ? 'сервер готов · ' + A.dt(h.time, { sec: true }) : 'есть ошибки'], ['База данных', (s.database.file || '') + ' · ' + A.bytes(s.database.size_bytes) + ' · агрегатов: ' + s.database.equipment],
        ['Учётные записи', s.users.total + ' · активных ' + s.users.active], ['Телеметрия', s.telemetry.map(function (t) { return t.equipment_id + (t.available ? ' - лента есть' : ' - ' + t.reason); }).join('; ') || 'нет агрегатов с лентой'],
        ['Распознавание', 'ONNX на процессоре · ' + models.length + ' модели']];
      if (m) kv.push(['Система', m.platform + ' · Python ' + m.python + ' · узел ' + m.host]);
      return { title: 'Обзор системы', sub: 'Состояние сервера по GET /system/status, /health и /webadmin/metrics · ' + A.dt(s.time, { sec: true }),
        body: W.kpis([
          { label: 'Время работы', icon: 'clock', value: A.dur(s.uptime_s), note: 'с ' + A.dt(s.started_at) },
          { label: 'База данных', icon: 'database', value: A.bytes(s.database.size_bytes), note: s.database.file },
          { label: 'Модели', icon: 'cpu', value: (det.loaded ? models.length : 0) + ' из ' + models.length, status: det.ready ? '' : 'warn', note: det.loaded ? 'загружены' : 'загрузка в фоне' },
          { label: 'Время кадра', icon: 'timer', value: bench ? num(bench.ms, 0) : '—', unit: bench ? 'мс' : '', note: bench ? 'замер ' + A.dt(bench.at, { time: true, sec: true }) : 'нажмите «Замерить»' },
          { label: 'Открытых сеансов', icon: 'phone', value: String(s.open_sessions), note: 'телефоны и браузеры' },
          { label: 'Активные тревоги', icon: 'alert', value: String(alarms.length), status: alarms.length ? 'warn' : '', note: 'по диагнозу и уставкам' }]) +
          '<div class="wgrid wg-21">' +
            W.panel({ title: 'Нагрузка процессора', sub: 'Средняя загрузка за минуту относительно числа ядер · замеры с открытия страницы', right: W.btn('Замерить распознавание', { kind: 'secondary', size: 'sm', icon: 'timer', attrs: 'data-bench="1"' }), body: '<div data-cpu="1">' + cpuChart() + '</div>' }) +
            W.panel({ title: 'Ресурсы', sub: m ? (m.host + ' · ' + m.cpu.cores + ' ядер') : 'метрики недоступны', body: m ?
              W.gauge({ value: m.cpu.percent || 0, max: 100, warn: 70, alarm: 90, unit: '%', label: 'Процессор · ' + m.cpu.cores + ' ядер', text: m.cpu.percent != null ? num(m.cpu.percent, 0) : '—' }) +
              '<div class="wcol">' + W.meter('Память процесса (пик)', A.bytes(m.memory.process_peak_bytes) + ' из ' + A.bytes(m.memory.total_bytes), memPct || 0) +
                (m.disk ? W.meter('Диск под базой', (diskPct || 0) + ' % · ' + A.bytes(m.disk.used_bytes) + ' из ' + A.bytes(m.disk.total_bytes), diskPct || 0, diskPct > 90 ? 'bad' : diskPct > 75 ? 'warn' : '') : '') +
                W.meter('База данных ' + (s.database.file || ''), A.bytes(s.database.size_bytes), Math.min(100, (s.database.size_bytes || 0) / (1024 * 1024 * 1024) * 100)) + '</div>' +
              '<span class="wmicro">Загрузка 1 / 5 / 15 мин: ' + [m.cpu.load_1, m.cpu.load_5, m.cpu.load_15].map(function (x) { return x == null ? '—' : num(x, 2); }).join(' / ') + '</span>'
              : A.unavailable('Метрики недоступны', 'Сервер не вернул /webadmin/metrics') }) +
          '</div>' +
          '<div class="wgrid wg-3">' +
            W.panel({ title: 'Оборудование', sub: d.equipment.length + ' агрегата в базе', right: W.link('Реестр', { arrow: true, attrs: 'data-route="equipment"' }), body: '<div class="wlist">' + units + '</div>' }) +
            W.panel({ title: 'Активные тревоги', sub: 'Диагноз на текущий момент ленты телеметрии', right: W.link('Телеметрия', { arrow: true, attrs: 'data-route="telemetry"' }), body: '<div class="wlist">' + alarmHtml + '</div>' }) +
            W.panel({ title: 'Распознавание', sub: (det.loaded ? models.length : 0) + ' из ' + models.length + ' моделей загружены', right: W.link('Модели', { arrow: true, attrs: 'data-route="models"' }), body: '<div class="wlist">' + modelHtml + '</div>' }) +
          '</div>' +
          W.panel({ title: 'Сервер', sub: 'Ответ GET /health · ' + A.dt(h.time, { sec: true }) + ' · база данных ' + (h.database === 'ok' ? 'в порядке' : 'с ошибкой'), right: W.btn('Скопировать сведения', { kind: 'ghost', size: 'sm', icon: 'copy', attrs: 'data-copy-info="1"' }), body: W.kv(kv, { cols: true }) }) };
    },
    after: function (main, d) {
      var box = main.querySelector('[data-cpu]');
      var draw = function () { box.innerHTML = cpuChart(); W.typo(box); if (samples.length >= 2) W.chartAfter(box, cpuChartOpts()); };
      draw();
      var sample = function () { A.get('/webadmin/metrics').then(function (m) { if (!document.contains(box)) return; note(m); draw(); }, function () { return null; }); };
      if (samples.length < 2) timers.push(setTimeout(sample, 2500));
      timers.push(setInterval(sample, 10000));
      main.querySelector('[data-bench]').addEventListener('click', function (e) {
        A.busy(e.currentTarget, A.post('/webadmin/models/benchmark')).then(function (r) {
          bench = r;
          A.toast('Замер выполнен', 'Распознавание кадра 640 × 480: ' + num(r.ms, 0) + ' мс (с подготовкой ' + num(r.total_ms, 0) + ' мс)', 'ok', 'timer');
          A.reload();
        }, function (err) { A.fail(err, 'Замер не выполнен'); });
      });
      main.querySelector('[data-copy-info]').addEventListener('click', function () {
        var s = d.status;
        var text = 'КСТ Визор · ' + location.host + '\nВремя работы: ' + A.dur(s.uptime_s) + '\nБаза: ' + s.database.file + ', ' + A.bytes(s.database.size_bytes) + '\nМодели: ' + ((s.detector || {}).models || []).join(', ') + '\nСеансов: ' + s.open_sessions;
        A.copy(text).then(function (ok) { A.toast(ok ? 'Сведения скопированы' : 'Не удалось скопировать', 'Адрес, время работы, база и модели - для заявки в поддержку', ok ? 'ok' : 'warn', 'copy'); });
      });
    } });

  /* ---------- Реестр оборудования ---------- */
  A.page('equipment', { title: 'Реестр оборудования', guard: function () { return A.isAdmin() && A.can('equipment.view'); },
    load: function () { return A.get('/equipment'); },
    render: function (list) {
      var rows = list.map(function (u) {
        return { key: u.mode + (u.telemetry ? ' tele' : ''), text: [u.id, u.name, u.model, u.serial, u.location, u.manufacturer].join(' '),
          cells: ['<div class="wcell"><div><span class="t-main">' + esc(u.id) + ' · ' + esc(u.name) + '</span><span class="t-sub">' + esc(u.manufacturer || '') + ' · ' + esc(u.model) + '</span></div></div>', '<span class="wmono">' + esc(u.serial) + '</span>', esc(u.location), modeChip(u.mode),
            num(u.run_hours, 0) + ' ч', u.telemetry ? A.chip('Есть', 'info') : '<span class="wt-3">нет</span>', u.open_findings ? A.chip(String(u.open_findings), 'warn') : '<span class="wt-3">нет</span>', icon('chevronRight', 18)] };
      });
      var html = W.table([{ label: 'Агрегат' }, { label: 'Заводской №' }, { label: 'Место' }, { label: 'Режим' }, { label: 'Наработка', cls: 'nw' }, { label: 'Телеметрия' }, { label: 'Замечания' }, { label: '', cls: 'chev' }], rows,
        { empty: W.empty({ icon: 'search', title: 'Агрегаты не найдены', text: 'Поиск идёт по коду, названию, модели, заводскому номеру и месту.' }) });
      var k = 0;
      html = html.replace(/<tr class="" {2}data-key/g, function () { return '<tr class="" data-eq="' + esc(list[k++].id) + '" role="button" tabindex="0" data-key'; });
      return { title: 'Реестр оборудования', sub: list.length + ' агрегата · GET /equipment · карточки читаются из базы сервера',
        body: W.note('Правка карточек и уставок в этой версии сервера недоступна: API оборудования только для чтения. Режим агрегата меняет мастер в приложении.', { icon: 'info' }) +
          '<div class="wcol"><div class="wtoolbar">' + W.search('Код, модель, заводской номер') + W.filters([{ label: 'Все', count: list.length, key: '', on: true }, { label: 'В работе', key: 'running', dot: 'ok', count: list.filter(function (u) { return u.mode === 'running'; }).length }, { label: 'Остановлены', key: 'stopped', dot: 'unk', count: list.filter(function (u) { return u.mode === 'stopped'; }).length }, { label: 'С телеметрией', key: 'tele', dot: 'info', count: list.filter(function (u) { return u.telemetry; }).length }], { group: 'm' }) + '</div></div>' + html };
    },
    after: function (main) {
      W.bindFilter(main, {});
      Array.prototype.forEach.call(main.querySelectorAll('[data-eq]'), function (tr) { tr.addEventListener('click', function () { eqDrawer(tr.getAttribute('data-eq')); }); });
    } });

  var SPEC = { power_kw: ['Мощность', 'кВт'], speed_rpm: ['Частота вращения', 'об/мин'], flow_m3h: ['Подача', 'м³/ч'], head_m: ['Напор', 'м'], max_pressure_bar: ['Наибольшее давление', 'бар'], rated_current_a: ['Номинальный ток', 'А'], insulation_class: ['Класс изоляции', ''], protection: ['Степень защиты', ''] };
  function eqDrawer(id) {
    Promise.all([A.get('/equipment/' + encodeURIComponent(id)), A.get('/equipment/' + encodeURIComponent(id) + '/nodes')]).then(function (d) {
      var u = d[0], nodes = d[1];
      var specs = Object.keys(u.specs || {}).map(function (k) { var s = SPEC[k] || [k, '']; var v = u.specs[k]; return [s[0], (typeof v === 'number' ? num(v) : v) + (s[1] ? ' ' + s[1] : '')]; });
      var g = u.gauge;
      A.open(W.drawer({ wide: true, title: u.id + ' · ' + u.name, sub: (u.manufacturer || '') + ' · ' + u.model + ' · № ' + u.serial, chips: modeChip(u.mode) + W.tag(num(u.run_hours, 0) + ' ч') + (u.telemetry ? W.tag('телеметрия', 'brand') : ''), body:
        '<div class="wdsec"><h3>Паспорт</h3>' + W.kv([['Место', u.location], ['Тип', u.type], ['Введён', u.commissioned ? A.dt(u.commissioned, { date: true }) : '—'], ['Наработка', num(u.run_hours, 0) + ' ч']]) + '</div>' +
        (specs.length ? '<div class="wdsec"><h3>Характеристики</h3>' + W.kv(specs) + '</div>' : '') +
        (g ? '<div class="wdsec"><h3>Стрелочный манометр</h3><div class="wrow" style="gap:16px;align-items:center">' + W.dial({ min: g.min, max: g.max, sweep: g.sweep_deg, value: (g.min + g.max) / 2 }) + W.kv([['Шкала', num(g.min) + '…' + num(g.max) + ' ' + g.unit], ['Угол шкалы', num(g.sweep_deg) + '°'], ['Сравнение', 'с датчиком ' + g.parameter]]) + '</div></div>' : '') +
        '<div class="wdsec"><h3>Узлы <span class="wmicro">' + nodes.length + '</span></h3><div class="wlist">' + nodes.map(function (n) {
          return W.li({ icon: 'layers', title: n.name, text: (n.norm_hours ? 'ресурс ' + num(n.norm_hours) + ' ч · ' : '') + (n.hours != null ? 'наработка ' + num(n.hours, 0) + ' ч' : '') + (n.classes && n.classes.length ? ' · камера: ' + n.classes.join(', ') : '') });
        }).join('') + '</div></div>' +
        ((u.maintenance || []).length ? '<div class="wdsec"><h3>Регламент ТО</h3>' + W.kv(u.maintenance.map(function (m) { return [m.name + ' · каждые ' + num(m.interval_hours) + ' ч', 'последнее на ' + num(m.last_at_hours) + ' ч · ' + m.work]; })) + '</div>' : '') +
        ((u.documents || []).length ? '<div class="wdsec"><h3>Документы <span class="wmicro">' + u.documents.length + '</span></h3><div class="wlist">' + u.documents.map(function (doc) { return W.li({ icon: 'file', title: doc.title || doc.name || doc.id, text: doc.kind || doc.type || '' }); }).join('') + '</div></div>' : ''),
        foot: '<span class="wgrow">Карточка только для чтения в этой версии</span>' + W.btn('Закрыть', { kind: 'primary', close: true }) }));
    }, function (err) { A.fail(err, 'Карточка не открылась'); });
  }

  /* ---------- Телеметрия и сценарии ---------- */
  var tel = { unit: null };
  function ms(iso) { return new Date(iso).getTime(); }
  A.page('telemetry', { title: 'Телеметрия и сценарии', guard: function () { return A.isAdmin() && A.can('telemetry.view'); },
    load: function () {
      return A.get('/equipment').then(function (list) {
        var withTel = list.filter(function (u) { return u.telemetry; });
        var id = tel.unit && list.some(function (u) { return u.id === tel.unit; }) ? tel.unit : (withTel[0] || list[0] || {}).id;
        tel.unit = id;
        var u = list.filter(function (x) { return x.id === id; })[0];
        if (!u || !u.telemetry) return { list: list, unit: u, none: true };
        var e = encodeURIComponent(id);
        return Promise.all([A.get('/equipment/' + e + '/scenarios'), A.get('/equipment/' + e + '/telemetry'), A.get('/equipment/' + e + '/diagnosis')]).then(function (d) {
          return { list: list, unit: u, scenarios: d[0], tele: d[1], diag: d[2] };
        });
      });
    },
    render: function (d) {
      var seg = KV.segment(d.list.map(function (u) { return u.id; }), d.list.indexOf(d.unit), { cls: 'wa-unit-seg' });
      if (d.none) {
        return { title: 'Телеметрия и сценарии', sub: 'Пульт демонстрации · выбор агрегата', actions: seg,
          body: W.empty({ icon: 'activity', title: 'Для ' + (d.unit ? d.unit.id : 'агрегата') + ' нет ленты телеметрии', text: 'Сценарии и курсор времени доступны только для агрегата с телеметрией. Оценки по карточке и осмотрам - в приложении.' }) };
      }
      var t = d.tele, ctl = A.can('telemetry.control');
      var active = d.scenarios.filter(function (s) { return s.active; })[0];
      return { title: 'Телеметрия и сценарии', sub: 'Пульт демонстрации · изменения сразу видят телефоны и правила сервера', actions: seg,
        body: W.panel({ title: 'Время на стенде', sub: 'Лента телеметрии ' + d.unit.id + ' · база заказчика до ' + A.dt(t.customer_until) + ', далее модельные каналы', right: '<span class="wrow">' + (active ? W.tag('сценарий: ' + active.title.toLowerCase(), 'brand') : W.tag('сценарий не выбран')) + '</span>', body:
            '<div class="wspread" style="flex-wrap:wrap"><div class="wclock"><span class="wnum" data-clock-date>' + A.dt(t.at, { date: true }) + '</span><span class="wnum" data-clock-time>' + A.dt(t.at, { time: true }) + '</span><span class="wlabel" data-clock-state>пауза · шаг 1 ч за 2 с</span></div>' +
            '<div class="wsteps">' + [-24, -6, -1].map(function (h) { return W.btn('−' + Math.abs(h) + ' ч', { size: 'sm', kind: 'secondary', disabled: !ctl, attrs: 'data-tstep="' + h + '"' }); }).join('') +
              W.btn('', { kind: 'primary', size: 'sm', icon: 'play', disabled: !ctl, attrs: 'data-tplay="1"', label: 'Пустить время' }) +
              [1, 6, 24].map(function (h) { return W.btn('+' + h + ' ч', { size: 'sm', kind: 'secondary', disabled: !ctl, attrs: 'data-tstep="' + h + '"' }); }).join('') + '</div></div>' +
            ribbon(d.scenarios, t) +
            '<div class="wspread" style="flex-wrap:wrap"><div class="wlegend"><span><i class="grow"></i>рост параметра</span><span><i class="over"></i>параметр за уставкой</span><span><i class="model"></i>смоделированные данные</span></div>' +
            KV.segment(['1 ч за 2 с', '1 ч за 1 с', '6 ч за 1 с'], 0, { cls: 'wspeed' }) + '</div>' }) +
          W.sec({ title: 'Сценарии', sub: 'Выбор сценария ставит время на час наибольшего отклонения · ' + d.scenarios.length + ' сценариев, ' + d.scenarios.filter(function (s) { return s.source === 'customer'; }).length + ' по базе заказчика', body: '<div class="wgrid wg-3">' + d.scenarios.map(function (s) {
            return '<div class="wscn' + (s.active ? ' is-on' : '') + '" data-scn="' + esc(s.id) + '" role="button" tabindex="0"><div class="wscn-top"><b>' + esc(s.title) + '</b>' + (s.active ? A.chip('Включён', 'info') : '') + '</div><p>' + esc(s.description) + '</p>' +
              '<div class="wtags">' + (s.expected_rules || []).map(function (r) { return W.tag(r, 'mono'); }).join('') + W.src(s.source === 'model') + '</div></div>';
          }).join('') + '</div>' }) +
          '<div class="wcol l" data-live="1">' + liveHtml(d) + '</div>' };
    },
    after: function (main, d) {
      var seg = main.querySelector('.wa-unit-seg');
      if (seg) seg.addEventListener('click', function (e) {
        var b = e.target.closest('.seg-item'); if (!b) return;
        var idx = Array.prototype.indexOf.call(seg.querySelectorAll('.seg-item'), b);
        tel.unit = d.list[idx].id; A.reload();
      });
      if (d.none) return;
      var ctl = A.can('telemetry.control'), unit = encodeURIComponent(d.unit.id);
      var t = d.tele, at = ms(t.at), first = ms(t.bounds.first), last = ms(t.bounds.last);
      var dEl = main.querySelector('[data-clock-date]'), tEl = main.querySelector('[data-clock-time]'), stEl = main.querySelector('[data-clock-state]');
      var needle = main.querySelector('.wstrip-needle'), strip = main.querySelector('[data-strip]'), live = main.querySelector('[data-live]');
      var play = main.querySelector('[data-tplay]'), timer = null, busy = false;
      var speeds = [[1, 2000, '1 ч за 2 с'], [1, 1000, '1 ч за 1 с'], [6, 1000, '6 ч за 1 с']];
      var speed = function () { var it = main.querySelectorAll('.wspeed .seg-item'); for (var k = 0; k < it.length; k++) if (it[k].classList.contains('is-on')) return speeds[k]; return speeds[0]; };
      var show = function () {
        var iso = A.isoLocal(new Date(at));
        dEl.textContent = A.dt(iso, { date: true }); tEl.textContent = A.dt(iso, { time: true });
        needle.style.left = needleLeft(at, first, last);
      };
      var refreshLive = function () {
        return Promise.all([A.get('/equipment/' + unit + '/telemetry'), A.get('/equipment/' + unit + '/diagnosis'), A.get('/equipment/' + unit + '/scenarios')]).then(function (x) {
          d.tele = x[0]; d.diag = x[1]; d.scenarios = x[2];
          at = ms(x[0].at); show();
          live.innerHTML = liveHtml(d); W.typo(live);
          Array.prototype.forEach.call(main.querySelectorAll('[data-scn]'), function (c) {
            var s = x[2].filter(function (y) { return y.id === c.getAttribute('data-scn'); })[0];
            c.classList.toggle('is-on', !!(s && s.active));
          });
        });
      };
      var setAt = function (target) {
        target = Math.max(first, Math.min(last, target));
        busy = true;
        return A.post('/equipment/' + unit + '/cursor', { at: A.isoLocal(new Date(target)) }).then(function (r) {
          at = ms(r.at); show(); return refreshLive();
        }).then(function () { busy = false; }, function (err) { busy = false; stop(); A.fail(err, 'Время не изменено'); });
      };
      var stop = function () { clearInterval(timer); timer = null; play.classList.remove('is-on'); play.innerHTML = icon('play', 18); stEl.textContent = 'пауза · шаг ' + speed()[2]; };
      var start = function () {
        var sp = speed(); clearInterval(timer);
        play.classList.add('is-on'); play.innerHTML = icon('pause', 18); stEl.textContent = 'идёт · ' + sp[2];
        timer = setInterval(function () {
          if (!document.contains(play)) { clearInterval(timer); return; }
          if (busy) return;
          if (at >= last) { stop(); return; }
          setAt(at + sp[0] * 3600000);
        }, sp[1]);
        timers.push(timer);
      };
      if (!ctl) { stEl.textContent = 'только просмотр · нужно право «Управление лентой телеметрии»'; return; }
      play.addEventListener('click', function () { if (timer) stop(); else start(); });
      Array.prototype.forEach.call(main.querySelectorAll('[data-tstep]'), function (b) { b.addEventListener('click', function () { if (!busy) setAt(at + (+b.getAttribute('data-tstep')) * 3600000); }); });
      main.querySelector('.wspeed').addEventListener('click', function () { setTimeout(function () { if (timer) start(); else stEl.textContent = 'пауза · шаг ' + speed()[2]; }, 0); });
      strip.addEventListener('click', function (e) { var r = strip.getBoundingClientRect(); setAt(first + (e.clientX - r.left) / r.width * (last - first)); });
      Array.prototype.forEach.call(main.querySelectorAll('[data-scn]'), function (c) {
        c.addEventListener('click', function () {
          var s = d.scenarios.filter(function (y) { return y.id === c.getAttribute('data-scn'); })[0];
          if (!s) return;
          var m = A.open(W.modal({ icon: 'activity', title: 'Включить сценарий «' + s.title + '»?', text: 'Время стенда встанет на ' + A.dt(s.peak) + ' - час наибольшего отклонения. Телефоны и правила сервера увидят новые показания сразу.', size: 'm', body:
            W.kv([['Описание', s.description], ['Ожидаемые правила', (s.expected_rules || []).join(', ') || 'нет'], ['Данные', s.source === 'model' ? 'смоделированы сервером' : 'база заказчика'], ['Интервал', A.dt(s.onset) + ' - ' + A.dt(s.end)]]),
            actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Включить', { kind: 'primary', icon: 'play', attrs: 'data-ok="1"' }) }));
          m.querySelector('[data-ok]').addEventListener('click', function (e) {
            stop();
            A.busy(e.currentTarget, A.post('/equipment/' + unit + '/scenarios/' + encodeURIComponent(s.id))).then(function (r) {
              A.close(m); A.toast('Сценарий включён', s.title + ' · время стенда ' + A.dt(r.at), 'ok', 'activity'); A.reload();
            }, function (err) { A.fail(err, 'Сценарий не включён'); });
          });
        });
      });
      show();
    } });

  function needleLeft(at, first, last) { return 'clamp(6px, ' + ((at - first) / (last - first) * 100).toFixed(2) + '%, calc(100% - 6px))'; }
  function ribbon(scn, t) {
    var first = ms(t.bounds.first), last = ms(t.bounds.last), span = last - first;
    var p = function (x) { return ((ms(x) - first) / span * 100).toFixed(2) + '%'; };
    var w = function (a, b) { return Math.max(0.4, (ms(b) - ms(a)) / span * 100).toFixed(2) + '%'; };
    var bands = scn.filter(function (s) { return s.kind === 'fault'; }).map(function (s) {
      var on = s.active ? ' is-active' : '';
      if (s.source === 'model') return '<span class="wstrip-band model' + on + '" style="left:' + p(s.onset) + ';width:' + w(s.onset, s.end) + '" title="' + esc(s.title) + '"></span>';
      return '<span class="wstrip-band grow' + on + '" style="left:' + p(s.onset) + ';width:' + w(s.onset, s.start) + '" title="' + esc(s.title) + '"></span>' +
        '<span class="wstrip-band over' + on + '" style="left:' + p(s.start) + ';width:' + w(s.start, s.end) + '" title="' + esc(s.title) + '"></span>';
    }).join('');
    var ticks = [], step = Math.max(1, Math.round(span / 86400000 / 5));
    for (var d = new Date(first); d.getTime() <= last; d = new Date(d.getTime() + step * 86400000)) ticks.push(d);
    return '<div class="wstrip" data-strip="1" role="slider" aria-label="Время на стенде">' + bands + '<span class="wstrip-needle" style="left:' + needleLeft(ms(t.at), first, last) + '"></span></div>' +
      '<div class="wstrip-ticks">' + ticks.map(function (x) { return '<span style="left:' + ((x.getTime() - first) / span * 100).toFixed(2) + '%">' + A.pad(x.getDate()) + '.' + A.pad(x.getMonth() + 1) + '</span>'; }).join('') + '</div>';
  }
  function tile(p) {
    var st = p.level === 'alarm' ? 'bad' : p.level === 'warn' ? 'warn' : 'ok';
    var v = p.value, hi;
    var lim = p.direction === 'high' ? (p.alarm || p.warn) : null;
    hi = Math.max(lim ? lim * 1.25 : (p.baseline || v || 1) * 1.6, v || 0) || 1;
    var pos = v == null ? 0 : Math.max(0, Math.min(100, v / hi * 100));
    var a = p.direction === 'high' && p.warn != null ? p.warn / hi * 100 : 100, b = p.direction === 'high' && p.alarm != null ? p.alarm / hi * 100 : 100;
    if (p.direction === 'low') { a = 0; b = 0; }
    var digits = v != null && Math.abs(v) < 10 ? 2 : (Math.abs(v) < 100 ? 1 : 0);
    var foot = p.direction === 'high' && p.warn != null ? 'уставки ' + num(p.warn) + (p.alarm != null ? ' / ' + num(p.alarm) : '') : p.direction === 'low' && p.warn != null ? 'норма от ' + num(p.warn) : 'без уставки';
    return '<div class="wtile ' + st + '" title="' + esc(p.basis || '') + '"><div class="wtile-h"><span>' + esc(p.name) + '</span>' + (p.source === 'model' ? W.src(true) : '<i class="dot ' + st + '"></i>') + '</div>' +
      '<div class="wtile-v"><span class="wnum">' + (v == null ? '—' : num(v, digits)) + '</span><span class="wunit">' + esc(p.unit || '') + '</span></div>' +
      '<div class="wscale ' + st + '" style="--a:' + a.toFixed(1) + '%;--b:' + b.toFixed(1) + '%"><i style="left:' + pos.toFixed(1) + '%"></i></div>' +
      '<div class="wtile-f"><span>' + esc(foot) + '</span><span>' + (p.level ? (st === 'ok' ? 'норма' : st === 'warn' ? 'внимание' : 'тревога') : '') + '</span></div></div>';
  }
  function liveHtml(d) {
    var t = d.tele, f = d.diag.findings || [];
    var labels = t.labels ? 'Вибрация: ' + t.labels.vibration.text + ' · температура: ' + t.labels.temperature.text : '';
    return W.sec({ title: 'Показания ' + d.unit.id + ' на ' + A.dt(t.at), sub: 'Уставки заказчика; каналы с пометкой «модель» рассчитывает сервер' + (labels ? ' · ' + labels : ''), body: '<div class="wa-tiles">' + t.parameters.map(tile).join('') + '</div>' }) +
      W.panel({ title: 'Сработавшие правила', sub: f.length ? f.length + ' по текущему моменту ленты · ' + d.diag.status_title : 'по текущему моменту ленты', body: f.length
        ? '<div class="wlist">' + f.map(function (x) { return W.li({ tone: FSTATUS[x.status] || '', icon: x.status === 'defect' ? 'alert' : x.status === 'check' ? 'alertCircle' : 'info', titleHtml: '<span class="wmono">' + esc(x.rule_id) + '</span> · ' + esc(x.title), text: (x.node_name || '') + (x.severity_title ? ' · ' + x.severity_title : '') + (x.recommendation ? ' · ' + x.recommendation : '') }); }).join('') + '</div>' +
          W.note('Это признаки возможного дефекта по данным ленты. Решение по агрегату принимает инженер после осмотра.', { icon: 'info' })
        : W.note(esc(d.diag.status_note || 'Срабатываний правил нет. Это не заключение об исправности: осмотры идут по графику.'), { icon: 'info' }) });
  }

  /* ---------- Модели распознавания ---------- */
  A.page('models', { title: 'Модели распознавания', guard: function () { return A.isAdmin(); },
    load: function () { return A.get('/webadmin/models'); },
    render: function (d) {
      var det = d.detector || {};
      var cards = d.models.map(function (m) {
        var metrics = [];
        Object.keys(m.measured || {}).forEach(function (k) {
          var v = m.measured[k];
          if (v && typeof v === 'object') metrics.push('<tr><td class="wa-mono">' + esc(k) + '</td>' + [['precision', 'box_precision'], ['recall', 'box_recall'], ['map50', 'map50_served']].map(function (keys) { var x = v[keys[0]] != null ? v[keys[0]] : v[keys[1]]; return '<td>' + (x != null ? num(x, 3) : '—') + '</td>'; }).join('') + '</tr>');
        });
        return W.panel({ cls: 'wa-model', title: m.file + (m.family ? ' · ' + m.family : ''), sub: (m.role === 'stand' ? 'узлы и дефекты стенда' : m.role || '') + ' · ' + (m.size_mb ? num(m.size_mb, 1) + ' МБ' : A.bytes(m.size_bytes)),
          right: m.loaded ? A.chip('Загружена', 'ok') : m.present ? A.chip('Файл на месте', 'info') : A.chip('Нет файла', 'bad'), body:
          W.kv([['Лицензия весов', m.weights_licence || '—'], ['Лицензия кода', m.code_licence || '—'], ['Вход', m.imgsz ? m.imgsz + ' px' : '—'],
            ['Порог «проверить»', m.conf_check != null ? num(m.conf_check, 2) : '—'], ['Порог «дефект»', m.conf_defect != null ? num(m.conf_defect, 2) : '—'], ['Обучение', m.trained_from || '—'], ['Данные', m.data || '—']]) +
          '<div class="wdsec"><h3>Классы <span class="wmicro">' + (m.classes || []).length + '</span></h3><div class="wa-classes">' + (m.classes || []).map(function (c) { return W.tag(c, (m.defect_classes || []).indexOf(c) >= 0 ? 'warn mono' : 'mono'); }).join('') + '</div></div>' +
          (metrics.length ? '<div class="wdsec"><h3>Метрики проверки</h3><div class="wtbl-wrap"><table class="wtbl dense"><thead><tr><th>Выборка</th><th>Precision</th><th>Recall</th><th>mAP50</th></tr></thead><tbody>' + metrics.join('') + '</tbody></table></div></div>' : '') });
      }).join('');
      return { title: 'Модели распознавания', sub: 'Описание из ' + d.manifest + ' · состояние детектора из сервера · файлы моделей здесь не меняются',
        actions: W.btn('Замерить время кадра', { kind: 'primary', icon: 'timer', attrs: 'data-bench="1"' }),
        body: W.kpis([{ label: 'Моделей в описании', icon: 'cpu', value: String(d.models.length), note: d.manifest },
          { label: 'Загружены', icon: 'checkCircle', value: String(d.models.filter(function (m) { return m.loaded; }).length), status: det.ready ? '' : 'warn', note: det.loaded ? 'детектор готов' : 'загрузка в фоне' },
          { label: 'Время кадра', icon: 'timer', value: bench ? num(bench.ms, 0) : '—', unit: bench ? 'мс' : '', note: bench ? 'кадр 640 × 480 · ' + A.dt(bench.at, { time: true, sec: true }) : 'замер по кнопке' },
          { label: 'Нет файлов', icon: 'alert', value: String((det.missing || []).length), status: (det.missing || []).length ? 'bad' : '', note: (det.missing || []).join(', ') || 'все на месте' }]) +
          (det.note ? W.note(esc(det.note), { tone: 'warn', icon: 'alert' }) : '') +
          W.note('Замена и откат моделей, правка порогов из панели недоступны в этой версии: модели обновляются файлами в папке models и описанием models.json.', { icon: 'info' }) +
          '<div class="wgrid" style="grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;align-items:start">' + cards + '</div>' };
    },
    after: function (main) {
      main.querySelector('[data-bench]').addEventListener('click', function (e) {
        A.busy(e.currentTarget, A.post('/webadmin/models/benchmark')).then(function (r) {
          bench = r; A.toast('Замер выполнен', 'Кадр 640 × 480 через все модели: ' + num(r.ms, 0) + ' мс', 'ok', 'timer'); A.reload();
        }, function (err) { A.fail(err, 'Замер не выполнен'); });
      });
    } });

  /* ---------- Журнал и резервные копии ---------- */
  A.page('log', { title: 'Журнал и резервные копии', guard: function () { return A.isAdmin(); },
    load: function () { return Promise.all([A.get('/webadmin/events?limit=300'), A.get('/webadmin/backups')]); },
    render: function (d) {
      var ev = d[0], bk = d[1];
      var KIND = { server: 'Сервер', inspection: 'Осмотры', finding: 'Находки' };
      var rows = ev.map(function (e) {
        return { key: e.kind + ' ' + e.level, text: [e.title, e.text, KIND[e.kind]].join(' '), cells: ['<span class="wmono">' + esc(A.dt(e.at, { sec: true })) + '</span>', W.level(e.level), esc(KIND[e.kind] || e.kind), '<div class="wcell"><div><span class="t-main">' + esc(e.title) + '</span><span class="t-sub">' + esc(e.text || '') + '</span></div></div>'] };
      });
      var bkHtml = bk.backups.length ? '<div class="wlist">' + bk.backups.slice(0, 8).map(function (b) { return W.li({ tone: 'ok', icon: 'archive', title: b.file, text: A.dt(b.created_at, { sec: true }) + ' · ' + A.bytes(b.size_bytes) }); }).join('') + '</div>' : '<p class="wlabel">Резервных копий пока нет.</p>';
      return { title: 'Журнал и резервные копии', sub: 'События сервера из базы: запуск, осмотры, находки · копии базы SQLite',
        actions: W.btn('Создать копию', { kind: 'primary', icon: 'archive', attrs: 'data-backup="1"' }),
        body: '<div class="wgrid wg-side"><div class="wcol l">' +
          '<div class="wcol"><div class="wtoolbar">' + W.search('Текст события') + W.filters([{ label: 'Все', key: '', on: true, count: ev.length }, { label: 'Осмотры', key: 'inspection', dot: 'info' }, { label: 'Находки', key: 'finding', dot: 'warn' }, { label: 'Сервер', key: 'server', dot: 'ok' }], { group: 'k' }) + '</div></div>' +
          W.table([{ label: 'Время', cls: 'nw' }, { label: 'Уровень' }, { label: 'Раздел' }, { label: 'Событие' }], rows, { dense: true, empty: W.empty({ icon: 'search', title: 'Событий не найдено', text: 'Измените раздел или текст поиска.' }) }) +
        '</div><div class="wcol l">' +
          W.panel({ title: 'Резервные копии', sub: 'Папка ' + bk.folder, body: bkHtml }) +
          W.panel({ cls: 'quiet', title: 'Восстановление', body: '<p class="wlabel">Восстановление копии из панели недоступно в этой версии: остановите сервер и замените файл базы копией из папки backups.</p>' }) +
        '</div></div>' };
    },
    after: function (main) {
      W.bindFilter(main, { scope: '.wcol.l' });
      main.querySelector('[data-backup]').addEventListener('click', function () {
        var m = A.open(W.modal({ icon: 'archive', title: 'Создать резервную копию базы?', text: 'Сервер скопирует базу SQLite штатным механизмом, без остановки. Идущие осмотры не прерываются.', size: 's',
          actions: W.btn('Отмена', { kind: 'ghost', close: true }) + W.btn('Создать', { kind: 'primary', icon: 'archive', attrs: 'data-ok="1"' }) }));
        m.querySelector('[data-ok]').addEventListener('click', function (e) {
          A.busy(e.currentTarget, A.post('/webadmin/backups')).then(function (r) {
            A.close(m); A.toast('Копия создана', r.file + ' · ' + A.bytes(r.size_bytes), 'ok', 'archive'); A.reload();
          }, function (err) { A.fail(err, 'Копия не создана'); });
        });
      });
    } });
})();
