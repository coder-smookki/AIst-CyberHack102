(function () {
  'use strict';
  var KV = window.KV = window.KV || {};
  KV.screens = KV.screens || {};
  KV.flows = KV.flows || [];
  KV.ASSETS = KV.ASSETS || {};
  var uidN = 0;
  KV.uid = function (p) { uidN += 1; return (p || 'kv') + uidN; };
  KV.esc = function (s) {
    return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  };
  KV.num = function (v, digits) {
    if (v == null || v === '') return '';
    var d = digits == null ? (Math.abs(v) < 10 && v % 1 !== 0 ? 1 : 0) : digits;
    var s = Number(v).toFixed(d);
    var parts = s.split('.');
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
    return parts.join(',');
  };
  KV.css = function (text) {
    var st = document.createElement('style'); st.setAttribute('data-kv', ''); st.textContent = text; (document.head || document.documentElement).appendChild(st);
  };
  var UNIT_RE = /(\d) (?=(°C|мм\/с|бар|ч|А|g|%|дн|МБ|КБ|ГБ|мин|сут|с|мс|кВт|м³\/ч|об\/мин)(?![а-яА-ЯёЁa-zA-Z]))/g;
  var ID_RE = /([A-Za-zА-ЯЁ]{1,4}-\d+)/;
  KV.typo = function (root) {
    if (!root || !document.createTreeWalker) return;
    var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null), list = [], n;
    while ((n = w.nextNode())) list.push(n);
    list.forEach(function (t) {
      var par = t.parentNode;
      if (!par || !par.closest || par.closest('svg, .nw, .d-nw, style, script')) return;
      var v = t.nodeValue.replace(UNIT_RE, '$1 ').replace(/(\d) (\d{3})(?!\d)/g, '$1 $2').replace(/([А-ЯЁ]\.) (?=[А-ЯЁ])/g, '$1 ');
      var m = v.match(ID_RE);
      if (m && m[0] !== v.trim()) {
        var parts = v.split(new RegExp(ID_RE.source, 'g')), box = document.createElement('span');
        parts.forEach(function (part, i) {
          if (!part) return;
          if (i % 2) { var sp = document.createElement('span'); sp.className = 'nw'; sp.textContent = part; box.appendChild(sp); }
          else box.appendChild(document.createTextNode(part));
        });
        par.replaceChild(box, t);
      } else if (v !== t.nodeValue) t.nodeValue = v;
    });
  };
  KV.asset = function (name) { return KV.ASSETS[name] || ('assets/' + name); };
  KV.cls = function () { return Array.prototype.filter.call(arguments, Boolean).join(' '); };
  KV.STATUS_LABEL = { ok: 'Норма', warn: 'Внимание', bad: 'Авария', unk: 'Нет данных', info: 'Инфо' };
  KV.act = function (o) {
    if (!o) return '';
    var a = [];
    if (o.go) a.push('data-go="' + KV.esc(o.go) + '"');
    if (o.back) a.push('data-back="' + KV.esc(o.back) + '"');
    if (o.close) a.push('data-close="1"');
    if (o.toast) a.push('data-toast="' + KV.esc(o.toast) + '"');
    if (o.toastKind) a.push('data-toast-kind="' + KV.esc(o.toastKind) + '"');
    if (o.toastIcon) a.push('data-toast-icon="' + KV.esc(o.toastIcon) + '"');
    if (o.snack) a.push('data-snack="' + KV.esc(o.snack) + '"');
    if (o.snackAction) a.push('data-snack-action="' + KV.esc(o.snackAction) + '"');
    if (o.toggle) a.push('data-toggle="' + KV.esc(o.toggle) + '"');
    if (o.nav) a.push('data-nav="' + KV.esc(o.nav) + '"');
    if (o.wait) a.push('data-wait="' + (o.wait === true ? 900 : o.wait) + '"');
    if (o.closeAfter) a.push('data-close-after="1"');
    if (o.attrs) a.push(o.attrs);
    if (o.go || o.back || o.close || o.toast || o.snack) a.push('role="button" tabindex="0"');
    return a.join(' ');
  };
  function isAct(o) { return !!(o && (o.go || o.back || o.close || o.toast || o.snack || o.toggle)); }
  KV.isAct = isAct;
  var I = {
    grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="2"/><rect x="13.5" y="3.5" width="7" height="7" rx="2"/><rect x="3.5" y="13.5" width="7" height="7" rx="2"/><rect x="13.5" y="13.5" width="7" height="7" rx="2"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.2 2"/>',
    history: '<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1L3.5 8.5"/><path d="M3.5 4v4.5H8M12 7.5V12l3 2"/>',
    scan: '<path d="M4 8.5V6.5A2.5 2.5 0 0 1 6.5 4h2M15.5 4h2A2.5 2.5 0 0 1 20 6.5v2M20 15.5v2a2.5 2.5 0 0 1-2.5 2.5h-2M8.5 20h-2A2.5 2.5 0 0 1 4 17.5v-2M7.5 12h9"/>',
    chat: '<path d="M20.5 11.6a8.4 8.4 0 0 1-12.3 7.5L3.8 20.4l1.3-4.2a8.4 8.4 0 1 1 15.4-4.6z"/>',
    user: '<circle cx="12" cy="8" r="4"/><path d="M4.5 20.5c.4-3.7 3.6-6 7.5-6s7.1 2.3 7.5 6"/>',
    users: '<circle cx="9" cy="8.5" r="3.5"/><path d="M2.5 20c.3-3.4 3-5.5 6.5-5.5s6.2 2.1 6.5 5.5"/><path d="M15.5 5a3.5 3.5 0 0 1 0 7M17.5 14.7c2.2.6 3.7 2.4 4 5.3"/>',
    userPlus: '<circle cx="9.5" cy="8" r="4"/><path d="M2.5 20.5c.4-3.7 3.4-6 7-6 1.6 0 3 .4 4.2 1.2M18.5 13v7M15 16.5h7"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.6-3.6"/>',
    chevronRight: '<path d="m9.5 6 6 6-6 6"/>',
    chevronLeft: '<path d="m14.5 6-6 6 6 6"/>',
    chevronDown: '<path d="m6 9.5 6 6 6-6"/>',
    chevronUp: '<path d="m6 14.5 6-6 6 6"/>',
    back: '<path d="m14.5 6-6 6 6 6"/>',
    arrowLeft: '<path d="M19 12H5M11 18l-6-6 6-6"/>',
    arrowRight: '<path d="M5 12h14M13 6l6 6-6 6"/>',
    arrowUp: '<path d="M12 19V5M6 11l6-6 6 6"/>',
    arrowDown: '<path d="M12 5v14M6 13l6 6 6-6"/>',
    more: '<circle cx="5.5" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="18.5" cy="12" r="1.4" fill="currentColor" stroke="none"/>',
    alert: '<path d="M10.3 4.2 2.7 17.4A2 2 0 0 0 4.4 20.4h15.2a2 2 0 0 0 1.7-3L13.7 4.2a2 2 0 0 0-3.4 0z"/><path d="M12 9.5v4M12 17h.01"/>',
    alertCircle: '<circle cx="12" cy="12" r="9"/><path d="M12 7.8v4.7M12 16.2h.01"/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
    checkCircle: '<circle cx="12" cy="12" r="9"/><path d="m8 12.3 2.8 2.8L16.2 9.5"/>',
    finger: '<path d="M12 10.5a1.5 1.5 0 0 0-1.5 1.5c0 1.1-.1 2.6-.3 4"/><path d="M14 13.1c0 2.4 0 6.4-1 8.9"/><path d="M17.3 21c.1-.6.4-2.3.5-3"/><path d="M2.5 12a9.5 9.5 0 0 1 17.2-5.6"/><path d="M2.5 16h.01"/><path d="M21.6 16c.2-2 .1-5.4 0-6"/><path d="M5 19.5c.5-1.5 1-4.5 1-7.5a6 6 0 0 1 .4-2"/><path d="M8.7 22c.2-.7.4-1.3.6-2"/><path d="M9 6.8a6 6 0 0 1 9 5.2v2"/>',
    face: '<path d="M4 8.5V6.5A2.5 2.5 0 0 1 6.5 4h2M15.5 4h2A2.5 2.5 0 0 1 20 6.5v2M20 15.5v2a2.5 2.5 0 0 1-2.5 2.5h-2M8.5 20h-2A2.5 2.5 0 0 1 4 17.5v-2"/><path d="M9 9.5v1M15 9.5v1M12 9.5v3.5h-1M9.2 15.4a4 4 0 0 0 5.6 0"/>',
    server: '<rect x="3.5" y="4" width="17" height="7" rx="2"/><rect x="3.5" y="13" width="17" height="7" rx="2"/><path d="M7.5 7.5h.01M7.5 16.5h.01M11 7.5h2M11 16.5h2"/>',
    sync: '<path d="M20 11a8 8 0 0 0-14.4-4.6L4 8.5M4 4v4.5h4.5M4 13a8 8 0 0 0 14.4 4.6L20 15.5M20 20v-4.5h-4.5"/>',
    file: '<path d="M14 3.5H7.5a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V8z"/><path d="M14 3.5V8h4.5M9 12.5h6M9 16h4"/>',
    filePdf: '<path d="M14 3.5H7.5a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V8z"/><path d="M14 3.5V8h4.5"/><path d="M8.5 17v-4h1.3a1.2 1.2 0 0 1 0 2.4H8.5M12.5 17v-4h.8a2 2 0 0 1 0 4zM16 13h-1.4v4M14.6 15H16"/>',
    fileXls: '<path d="M14 3.5H7.5a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V8z"/><path d="M14 3.5V8h4.5"/><path d="M9 12.5l3.5 4.5M12.5 12.5 9 17M14.5 12.5V17h2"/>',
    download: '<path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/>',
    upload: '<path d="M12 20V9M7 13.5l5-5 5 5M5 4h14"/>',
    share: '<path d="M12 3.5v11M7.5 8 12 3.5 16.5 8M5 13.5v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5"/>',
    link: '<path d="M10 14a4.5 4.5 0 0 0 6.4 0l3-3a4.5 4.5 0 0 0-6.4-6.4l-1 1"/><path d="M14 10a4.5 4.5 0 0 0-6.4 0l-3 3a4.5 4.5 0 0 0 6.4 6.4l1-1"/>',
    send: '<path d="M20.5 3.5 10 14M20.5 3.5 14 20.5l-4-6.5-6.5-4z"/>',
    gauge: '<path d="M3.6 17.5a9 9 0 1 1 16.8 0"/><path d="m12 14 4-4"/><circle cx="12" cy="14" r="1.4"/>',
    temp: '<path d="M14 14.6V5a2 2 0 0 0-4 0v9.6a4 4 0 1 0 4 0z"/><path d="M12 9v7.5"/>',
    wave: '<path d="M2.5 12c1.6-4.5 3.2-4.5 4.8 0s3.2 4.5 4.7 0 3.2-4.5 4.8 0 3.1 4.5 4.7 0"/>',
    activity: '<path d="M3 12h4l3-7.5 4 15 3-7.5h4"/>',
    flash: '<path d="M13 2.5 4.5 13.5H11l-1 8 8.5-11H12z"/>',
    close: '<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>',
    eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
    eyeOff: '<path d="M3.5 3.5l17 17M10.6 5.6A9 9 0 0 1 12 5.5c6 0 9.5 6.5 9.5 6.5a16 16 0 0 1-2.9 3.7M6.6 6.9C4 8.6 2.5 12 2.5 12S6 18.5 12 18.5a9 9 0 0 0 4.9-1.4M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
    mail: '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="m4 7.5 8 5.5 8-5.5"/>',
    lock: '<rect x="4.5" y="10.5" width="15" height="10" rx="3"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3M12 14.5v2"/>',
    unlock: '<rect x="4.5" y="10.5" width="15" height="10" rx="3"/><path d="M8 10.5V7.5a4 4 0 0 1 7.6-1.7M12 14.5v2"/>',
    bell: '<path d="M6 9.5a6 6 0 0 1 12 0c0 5.5 2.5 7 2.5 7h-17S6 15 6 9.5"/><path d="M10.2 20a2 2 0 0 0 3.6 0"/>',
    wrench: '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.4-3.4a6 6 0 0 1-7.9 7.9l-6.5 6.5a2.1 2.1 0 0 1-3-3l6.5-6.5a6 6 0 0 1 7.9-7.9z"/>',
    calendar: '<rect x="3.5" y="5" width="17" height="15.5" rx="3"/><path d="M3.5 10h17M8 3v4M16 3v4"/>',
    shield: '<path d="M12 3 4.5 6v5.6c0 4.5 3.2 8.2 7.5 9.4 4.3-1.2 7.5-4.9 7.5-9.4V6z"/>',
    shieldCheck: '<path d="M12 3 4.5 6v5.6c0 4.5 3.2 8.2 7.5 9.4 4.3-1.2 7.5-4.9 7.5-9.4V6z"/><path d="m9 12 2.2 2.2L15.5 10"/>',
    key: '<circle cx="7.5" cy="15.5" r="4"/><path d="M10.4 12.6 20 3M16.5 6.5l3 3M18.5 4.5l2 2"/>',
    database: '<ellipse cx="12" cy="5.5" rx="7.5" ry="2.8"/><path d="M4.5 5.5v13c0 1.5 3.4 2.8 7.5 2.8s7.5-1.3 7.5-2.8v-13M4.5 12c0 1.5 3.4 2.8 7.5 2.8s7.5-1.3 7.5-2.8"/>',
    cpu: '<rect x="5" y="5" width="14" height="14" rx="2.5"/><rect x="9" y="9" width="6" height="6" rx="1"/><path d="M9.5 2v3M14.5 2v3M9.5 19v3M14.5 19v3M2 9.5h3M2 14.5h3M19 9.5h3M19 14.5h3"/>',
    plug: '<path d="M9 2.5v4.5M15 2.5v4.5M6 7h12v3.5a6 6 0 0 1-12 0zM12 16.5v5"/>',
    list: '<path d="M9 6h11.5M9 12h11.5M9 18h11.5M4 6h.01M4 12h.01M4 18h.01"/>',
    filter: '<path d="M3.5 6h17M6.5 12h11M10 18h4"/>',
    menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
    sliders: '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    minus: '<path d="M5 12h14"/>',
    edit: '<path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16z"/><path d="m13.5 6.5 4 4"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>',
    camera: '<path d="M4 7.5h3l2-3h6l2 3h3a1 1 0 0 1 1 1V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8.5a1 1 0 0 1 1-1z"/><circle cx="12" cy="13" r="3.5"/>',
    map: '<path d="M9 4.5 3.5 6.5v13L9 17.5l6 2 5.5-2v-13L15 6.5z"/><path d="M9 4.5v13M15 6.5v13"/>',
    route: '<circle cx="6" cy="18.5" r="2.5"/><circle cx="18" cy="5.5" r="2.5"/><path d="M8.5 18.5H16a3.3 3.3 0 0 0 0-6.6H8a3.3 3.3 0 0 1 0-6.4h7.5"/>',
    pin: '<path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/>',
    star: '<path d="m12 3.5 2.6 5.4 5.9.8-4.3 4.1 1.1 5.8L12 16.8l-5.3 2.8 1.1-5.8-4.3-4.1 5.9-.8z"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5.5M12 7.8h.01"/>',
    logout: '<path d="M14.5 4H18a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3.5M9.5 16.5 5 12l4.5-4.5M5 12h11"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
    moon: '<path d="M20 14.5A8 8 0 1 1 9.5 4a6.3 6.3 0 0 0 10.5 10.5z"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M2.5 12h2M19.5 12h2M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>',
    sparkle: '<path d="M11 3.5 12.9 9 18.5 11l-5.6 2L11 18.5 9.1 13 3.5 11 9.1 9z"/><path d="M18.5 15.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z"/>',
    wifi: '<path d="M2.5 8.8a14 14 0 0 1 19 0M5.5 12.3a9.5 9.5 0 0 1 13 0M8.7 15.6a5 5 0 0 1 6.6 0M12 19h.01"/>',
    wifiOff: '<path d="M3 3l18 18M8.7 15.6a5 5 0 0 1 6.6 0M5.5 12.3a9.5 9.5 0 0 1 4-2.2M2.5 8.8A14 14 0 0 1 7 6M14 6.2a14 14 0 0 1 7.5 2.6M16 10.4a9.5 9.5 0 0 1 2.5 1.9M12 19h.01"/>',
    power: '<path d="M12 3v8M6.4 6.5a8 8 0 1 0 11.2 0"/>',
    pause: '<rect x="6.5" y="5" width="3.5" height="14" rx="1"/><rect x="14" y="5" width="3.5" height="14" rx="1"/>',
    play: '<path d="M7.5 4.8v14.4L19 12z"/>',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
    qr: '<rect x="3.5" y="3.5" width="6.5" height="6.5" rx="1.5"/><rect x="14" y="3.5" width="6.5" height="6.5" rx="1.5"/><rect x="3.5" y="14" width="6.5" height="6.5" rx="1.5"/><path d="M14 14h3v3h-3zM20.5 14v.01M14 20.5h.01M17 20.5h3.5V17"/>',
    tag: '<path d="M3.5 12V4.5a1 1 0 0 1 1-1H12l8.5 8.5-8.5 8.5z"/><circle cx="8" cy="8" r="1.5"/>',
    box: '<path d="M20.5 7.5 12 3 3.5 7.5v9L12 21l8.5-4.5z"/><path d="M3.5 7.5 12 12l8.5-4.5M12 12v9"/>',
    layers: '<path d="m12 3.5 9 4.5-9 4.5L3 8z"/><path d="m3 12 9 4.5 9-4.5M3 16l9 4.5 9-4.5"/>',
    drop: '<path d="M12 3.5s6 6.4 6 10.8a6 6 0 0 1-12 0C6 9.9 12 3.5 12 3.5z"/>',
    megaphone: '<path d="M3.5 10v4a1 1 0 0 0 1 1h2.5l6.5 4.5v-15L7 9H4.5a1 1 0 0 0-1 1z"/><path d="M17 9a4.5 4.5 0 0 1 0 6M19.5 6.5a8 8 0 0 1 0 11"/>',
    terminal: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="m7 9.5 3 2.5-3 2.5M12.5 15h4.5"/>',
    archive: '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4"/>',
    timer: '<circle cx="12" cy="13.5" r="7.5"/><path d="M12 9.5v4l2.5 1.5M9.5 2.5h5"/>',
    target: '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="3.5"/><path d="M12 1.5v4M12 18.5v4M1.5 12h4M18.5 12h4"/>',
    ban: '<circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/>',
    vibrate: '<rect x="8" y="4" width="8" height="16" rx="2"/><path d="M4.5 9v6M19.5 9v6M2 11v2M22 11v2"/>',
    copy: '<rect x="8.5" y="8.5" width="12" height="12" rx="2.5"/><path d="M15.5 8.5V6a2.5 2.5 0 0 0-2.5-2.5H6A2.5 2.5 0 0 0 3.5 6v7A2.5 2.5 0 0 0 6 15.5h2.5"/>',
    clipboard: '<rect x="5" y="4.5" width="14" height="16.5" rx="2.5"/><path d="M9 4.5V3.5h6v1M9 11h6M9 15h4"/>',
    flag: '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>',
    home: '<path d="M4 10.5 12 4l8 6.5V19a1.5 1.5 0 0 1-1.5 1.5h-4v-6h-5v6h-4A1.5 1.5 0 0 1 4 19z"/>',
    refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7M20 4.5V11h-6.5"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    phone: '<rect x="6.5" y="2.5" width="11" height="19" rx="2.5"/><path d="M11 18.5h2"/>',
    hash: '<path d="M5 9h15M4 15h15M10 3.5 8 20.5M16 3.5l-2 17"/>',
    signal: '<path d="M4 20v-3M9 20v-7M14 20V9M19 20V4"/>',
    hand: '<path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V12M11 11V4a1.5 1.5 0 0 1 3 0v7M14 11V5.5a1.5 1.5 0 0 1 3 0V14a7 7 0 0 1-7 7h-.5a6 6 0 0 1-4.6-2.2L3.5 16a1.6 1.6 0 0 1 2.4-2.1L8 16"/>'
  };
  KV.ICONS = I;
  KV.icon = function (name, size, cls) {
    var p = I[name] || I.info;
    var s = size || 24;
    return '<svg class="ic' + (cls ? ' ' + cls : '') + '" width="' + s + '" height="' + s + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + p + '</svg>';
  };
  KV.statusbar = function (time) {
    return '<div class="sbar"><span>' + KV.esc(time || '9:41') + '</span><span class="sbar-ic">' +
      '<svg width="18" height="12" viewBox="0 0 18 12" fill="currentColor"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1"/></svg>' +
      '<svg width="16" height="12" viewBox="0 0 16 12" fill="currentColor"><path d="M8 2.3c2.3 0 4.4.9 6 2.4l1.2-1.3A10.3 10.3 0 0 0 8 .5 10.3 10.3 0 0 0 .8 3.4L2 4.7a8.6 8.6 0 0 1 6-2.4zm0 3.4c1.4 0 2.6.5 3.6 1.4l1.2-1.3A7 7 0 0 0 8 3.9a7 7 0 0 0-4.8 1.9l1.2 1.3c1-.9 2.2-1.4 3.6-1.4zm0 3.4c-.6 0-1.1.2-1.5.6L8 11.3l1.5-1.6c-.4-.4-.9-.6-1.5-.6z"/></svg>' +
      '<svg width="27" height="13" viewBox="0 0 27 13"><rect x=".5" y=".5" width="23" height="12" rx="3.8" fill="none" stroke="currentColor" opacity=".38"/><rect x="2" y="2" width="20" height="9" rx="2.5" fill="currentColor"/><path d="M25 4.5v4c.8-.3 1.4-1.1 1.4-2s-.6-1.7-1.4-2z" fill="currentColor" opacity=".45"/></svg>' +
      '</span></div>';
  };
  KV.statusDot = function (status, text) {
    return '<span class="stat"><i class="dot ' + (status || 'unk') + '"></i><span>' + KV.esc(text) + '</span></span>';
  };
  KV.chip = function (text, status, o) {
    o = o || {};
    return '<span class="chip ' + (status || '') + (o.cls ? ' ' + o.cls : '') + '">' + (o.dot === false ? '' : '<i class="dot"></i>') + KV.esc(text) + '</span>';
  };
  KV.badge = function (n, o) { o = o || {}; return '<span class="badge' + (o.info ? ' info' : '') + (n == null ? ' dot-only' : '') + '">' + (n == null ? '' : KV.esc(n)) + '</span>'; };
  KV.header = function (o) {
    o = o || {};
    var left = o.left != null ? o.left : (o.back ? '<button class="btn-round" ' + KV.act({ back: o.back }) + ' aria-label="Назад">' + KV.icon('back') + '</button>' : '<span class="hdr-spacer"></span>');
    var moreAct = typeof o.more === 'string' ? { go: o.more } : o.more;
    var right = o.right != null ? o.right : (moreAct ? '<button class="btn-round" ' + KV.act(moreAct) + ' aria-label="Ещё">' + KV.icon('more') + '</button>' : '<span class="hdr-spacer"></span>');
    var sub = o.sub ? '<div class="hdr-sub">' + (o.status ? '<i class="dot ' + o.status + '"></i>' : '') + '<span>' + KV.esc(o.sub) + '</span></div>' : '';
    return '<header class="hdr">' + left + '<div class="hdr-mid"><div class="hdr-title">' + KV.esc(o.title) + '</div>' + sub + '</div>' + right + '</header>';
  };
  KV.rootHeader = function (o) {
    o = o || {};
    return '<header class="hdr-root"><div class="t-title">' + KV.esc(o.title) + '</div>' +
      (o.sub ? '<div class="hdr-sub">' + (o.status ? '<i class="dot ' + o.status + '"></i>' : '') + '<span>' + KV.esc(o.sub) + '</span></div>' : '') + '</header>';
  };
  function tag() { return 'div'; }
  KV.card = function (o) {
    o = o || {};
    var t = tag(o);
    var head = (o.title || o.right) ? '<div class="card-head"><div class="card-title">' + KV.esc(o.title || '') + '</div>' + (o.right || '') + '</div>' : '';
    return '<' + t + ' class="card' + (o.cls ? ' ' + o.cls : '') + (isAct(o) ? ' is-link' : '') + '" ' + KV.act(o) + (t === 'button' ? ' style="text-align:left;width:100%"' : '') + '>' + head + (o.body || '') + '</' + t + '>';
  };
  KV.tile = function (o) {
    o = o || {};
    var t = tag(o);
    var v = typeof o.value === 'number' ? KV.num(o.value, o.digits) : KV.esc(o.value);
    return '<' + t + ' class="tile' + (o.cls ? ' ' + o.cls : '') + '" ' + KV.act(o) + ' style="text-align:left">' +
      '<div class="tile-top"><span class="tile-label">' + KV.esc(o.label) + '</span>' + (o.status ? '<i class="dot ' + o.status + '"></i>' : '') + '</div>' +
      '<div class="tile-value"><span class="t-num-m">' + v + '</span>' + (o.unit ? '<span class="t-unit">' + KV.esc(o.unit) + '</span>' : '') + '</div>' +
      (o.spark ? '<div class="spark">' + KV.sparkline(o.spark) + '</div>' : '') + (o.extra || '') + '</' + t + '>';
  };
  KV.kpi = function (o) {
    var t = tag(o);
    return '<' + t + ' class="tile kpi ' + (o.status || '') + '" ' + KV.act(o) + ' style="text-align:left"><span class="t-num-l">' + KV.esc(o.value) + '</span><span class="tile-label">' + KV.esc(o.label) + '</span></' + t + '>';
  };
  KV.row = function (o) {
    o = o || {};
    var t = tag(o);
    var lead = o.avatar ? KV.avatar(o.avatar, o.avatarSize) : (o.icon ? '<span class="row-ic ' + (o.iconStatus || '') + '">' + KV.icon(o.icon, 22) + '</span>' : '');
    var chev = o.chevron === false ? '' : (o.chevron || isAct(o) && !o.toggle ? KV.icon('chevronRight', 20) : '');
    var end = (o.value != null ? '<span class="val">' + KV.esc(o.value) + '</span>' : '') + (o.end || '') + chev;
    return '<' + t + ' class="row' + (o.cls ? ' ' + o.cls : '') + '" ' + KV.act(o) + '>' + lead +
      '<span class="row-main"><span class="row-title">' + (o.titleHtml || KV.esc(o.title)) + '</span>' + (o.sub || o.subHtml ? '<span class="row-sub">' + (o.subHtml || KV.esc(o.sub)) + '</span>' : '') + '</span>' +
      (end ? '<span class="row-end">' + end + '</span>' : '') + '</' + t + '>';
  };
  KV.action = function (o) {
    return '<div class="act-card" ' + KV.act(o) + '><span class="row-ic ' + (o.iconStatus || '') + '">' + KV.icon(o.icon || 'info', 20) + '</span>' +
      '<span class="act-main"><span class="act-title">' + KV.esc(o.title) + '</span>' + (o.sub ? '<span class="act-sub">' + KV.esc(o.sub) + '</span>' : '') + '</span></div>';
  };
  KV.list = function (rows, o) {
    o = o || {};
    return '<div class="list' + (o.noIcons ? ' no-icons' : '') + (o.cls ? ' ' + o.cls : '') + '">' + (Array.isArray(rows) ? rows.join('') : rows) + '</div>';
  };
  KV.button = function (text, o) {
    o = o || {};
    var c = 'btn btn-' + (o.kind || 'primary') + (o.size === 'sm' ? ' sm' : '') + (o.auto ? ' auto' : '') + (o.loading ? ' is-loading' : '') + (o.cls ? ' ' + o.cls : '');
    return '<button class="' + c + '" ' + KV.act(o) + (o.disabled ? ' disabled' : '') + '>' + (o.icon ? KV.icon(o.icon, 20) : '') + '<span>' + KV.esc(text) + '</span>' + (o.iconRight ? KV.icon(o.iconRight, 20) : '') + '</button>';
  };
  KV.link = function (text, o) { return '<button class="link" ' + KV.act(o) + '>' + KV.esc(text) + '</button>'; };
  KV.field = function (o) {
    o = o || {};
    var dots = new Array((o.mask || 10) + 1).join('•');
    var val = o.value ? '<span class="val"' + (o.reveal ? ' data-reveal="' + KV.esc(o.reveal) + '"' : '') + '>' + (o.type === 'password' ? dots : KV.esc(o.value)) + '</span>' : '<span class="val ph">' + KV.esc(o.placeholder || '') + '</span>';
    var end = o.end ? '<button class="fic" ' + KV.act(o.endAct || { toggle: 'check' }) + ' aria-label="">' + KV.icon(o.end, 22) + '</button>' : '';
    return '<label class="field' + (o.focus ? ' is-focus' : '') + (o.error ? ' is-error' : '') + (o.area ? ' area' : '') + '">' +
      (o.label ? '<span class="field-label">' + KV.esc(o.label) + '</span>' : '') +
      '<span class="field-box">' + (o.lead ? '<span class="lead">' + KV.icon(o.lead, 20) + '</span>' : '') + val + end + '</span>' +
      (o.help ? '<span class="field-help">' + KV.esc(o.help) + '</span>' : '') + '</label>';
  };
  KV.search = function (placeholder, o) {
    o = o || { go: 'search' };
    return '<button class="search" ' + KV.act(o) + '>' + KV.icon('search', 20) + '<span>' + KV.esc(placeholder) + '</span></button>';
  };
  KV.segment = function (items, active, o) {
    o = o || {};
    var h = '<div class="seg' + (o.onBg ? ' on-bg' : '') + (o.tall ? ' tall' : '') + (o.cls ? ' ' + o.cls : '') + '" data-seg><span class="seg-ind"></span>';
    items.forEach(function (it, i) {
      var lab = typeof it === 'string' ? it : it.label;
      var a = (typeof it === 'object' && (it.go || it.toast)) ? KV.act({ go: it.go, toast: it.toast, nav: it.nav || 'seg' }) : KV.act({ toggle: 'seg' });
      if (i === active && typeof it === 'object' && it.go) a = KV.act({ toggle: 'seg' });
      h += '<button class="seg-item' + (i === active ? ' is-on' : '') + '" ' + a + '>' + KV.esc(lab) + '</button>';
    });
    return h + '</div>';
  };
  KV.toggle = function (on) { return '<span class="toggle' + (on ? ' is-on' : '') + '" data-toggle="switch" role="switch" aria-checked="' + (on ? 'true' : 'false') + '"></span>'; };
  KV.fchips = function (items, o) {
    o = o || {};
    return '<div class="fchips' + (o.cls ? ' ' + o.cls : '') + '">' + items.map(function (it) {
      var a = it.go ? KV.act({ go: it.go, nav: it.nav || 'fade' }) : KV.act({ toggle: o.multi ? 'chip' : 'radio' });
      return '<button class="fchip' + (it.on ? ' is-on' : '') + '" ' + a + '>' + KV.esc(it.label) + (it.count != null ? ' <span class="cnt">' + KV.esc(it.count) + '</span>' : '') + '</button>';
    }).join('') + '</div>';
  };
  KV.progress = function (pct, status, o) {
    o = o || {};
    return '<div class="progress ' + (status || '') + (o.thin ? ' thin' : '') + '"><i style="width:' + Math.max(0, Math.min(100, pct)) + '%"></i></div>';
  };
  KV.avatar = function (nameOrInitials, size) {
    var s = String(nameOrInitials || '');
    var ini = s.length <= 2 ? s : s.split(/\s+/).map(function (w) { return w.charAt(0); }).slice(0, 2).join('');
    return '<span class="avatar' + (size ? ' ' + size : '') + '">' + KV.esc(ini.toUpperCase()) + '</span>';
  };
  KV.timeline = function (items) {
    return '<div class="timeline">' + items.map(function (it) {
      var t = 'div';
      return '<' + t + ' class="tl-item" ' + KV.act(it) + ' style="text-align:left;width:100%"><span class="tl-dot ' + (it.status || 'unk') + '"></span><span><span class="tl-time">' + KV.esc(it.time) + '</span>' +
        '<span class="tl-title" style="display:block">' + KV.esc(it.title) + '</span>' + (it.text ? '<span class="tl-text" style="display:block">' + KV.esc(it.text) + '</span>' : '') + '</span></' + t + '>';
    }).join('') + '</div>';
  };
  KV.empty = function (o) {
    return '<div class="empty"><div class="empty-ic">' + KV.icon(o.icon || 'search', 32) + '</div><div class="empty-title">' + KV.esc(o.title) + '</div>' +
      (o.text ? '<div class="empty-text">' + KV.esc(o.text) + '</div>' : '') + (o.action ? '<div class="mt-m">' + o.action + '</div>' : '') + '</div>';
  };
  KV.note = function (text, o) {
    o = o || {};
    var t = 'div';
    return '<' + t + ' class="note ' + (o.tone || '') + '" ' + KV.act(o) + ' style="text-align:left">' + KV.icon(o.icon || 'sparkle', 20) + '<span>' + (o.html || KV.esc(text)) + '</span></' + t + '>';
  };
  KV.kvs = function (pairs) {
    return pairs.map(function (p) { return '<div class="kv"><span>' + KV.esc(p[0]) + '</span><span>' + KV.esc(p[1]) + '</span></div>'; }).join('');
  };
  KV.logo = function (variant, height) {
    return '<img class="logo-img" src="' + KV.asset(variant === 'white' ? 'kst_logo_white.png' : 'kst_logo_blue.png') + '" alt="КСТ ЭНЕРГО ИНЖИНИРИНГ" style="height:' + (height || 32) + 'px;width:' + Math.round((height || 32) * 1758 / 417) + 'px">';
  };
  KV.sheet = function (o) {
    o = o || {};
    return '<div class="sheet">' + (o.grab === false ? '' : '<div class="sheet-grab"></div>') +
      (o.title ? '<div class="sheet-head"><div class="sheet-title">' + KV.esc(o.title) + '</div>' + (o.close === false ? '' : '<button class="btn-round ghost" data-close="1" aria-label="Закрыть">' + KV.icon('close', 22) + '</button>') + '</div>' : '') +
      '<div class="sheet-body">' + (o.body || '') + '</div>' + (o.actions ? '<div class="vstack gap-s">' + o.actions + '</div>' : '') + '</div>';
  };
  KV.dialog = function (o) {
    o = o || {};
    return '<div class="dialog">' + (o.icon ? '<div class="dialog-ic ' + (o.tone || '') + '">' + KV.icon(o.icon, 28) + '</div>' : '') +
      '<div class="dialog-title">' + KV.esc(o.title) + '</div>' + (o.text ? '<div class="dialog-text">' + KV.esc(o.text) + '</div>' : '') + (o.body || '') +
      (o.actions || '') + '</div>';
  };
  KV.toast = function (o) {
    o = o || {};
    var k = o.kind || 'bad';
    var ic = o.icon || { bad: 'alert', ok: 'checkCircle', warn: 'alert', info: 'info' }[k];
    var act = isAct(o) ? KV.act({ go: o.go, nav: o.nav, toast: o.toastAct, back: o.back }) : '';
    return '<div class="toast ' + k + (act ? ' is-link' : '') + '"' + (act ? ' ' + act : '') + '><span class="toast-ic">' + KV.icon(ic, 20) + '</span><div class="grow"><div class="toast-title">' + KV.esc(o.title) + '</div>' +
      (o.text ? '<div class="toast-text">' + KV.esc(o.text) + '</div>' : '') + '</div></div>';
  };
  KV.snack = function (o) {
    o = o || {};
    return '<div class="snack">' + (o.icon ? '<span class="snack-ic">' + KV.icon(o.icon, 20) + '</span>' : '') + '<span class="snack-text">' + KV.esc(o.text) + '</span>' +
      (o.action ? '<button class="snack-act" ' + KV.act(o.action) + '>' + KV.esc(o.action.label) + '</button>' : '') + '</div>';
  };
  var IMG_AR = 780 / 1688;
  function pctS(v) { return v.toFixed(2) + '%'; }
  KV.cam = {
    view: function (k, cx, cy, tx, ty, elAspect) {
      var ky = k * (elAspect || IMG_AR) / IMG_AR;
      var clamp = function (v) { return Math.max(0, Math.min(1, v)); };
      var px = k > 1 ? clamp((k * cx - tx) / (k - 1)) : 0.5;
      var py = ky > 1 ? clamp((ky * cy - ty) / (ky - 1)) : 0.5;
      return {
        style: 'background-image:url(\'' + KV.asset('camera.jpg') + '\');background-size:' + (k * 100).toFixed(1) + '% auto;background-position:' + (px * 100).toFixed(2) + '% ' + (py * 100).toFixed(2) + '%;',
        map: function (d) { return { x: k * d.x - px * (k - 1) * 100, y: ky * d.y - py * (ky - 1) * 100, w: d.w * k, h: d.h * ky }; }
      };
    },
    det: function (label) { var ds = (KV.data && KV.data.detections) || []; for (var i = 0; i < ds.length; i++) if (ds[i].label === label) return ds[i]; return null; },
    pct: pctS,
    box: function (b, kind, act) {
      var x0 = Math.max(b.x, 0), y0 = Math.max(b.y, 0), x1 = Math.min(b.x + b.w, 100), y1 = Math.min(b.y + b.h, 100);
      b = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
      return '<div class="ar-box' + (kind && kind !== 'part' ? ' ' + kind : '') + '" style="left:' + pctS(b.x) + ';top:' + pctS(b.y) + ';width:' + pctS(b.w) + ';height:' + pctS(b.h) + '"' + (act ? ' ' + KV.act(act) + ' aria-label="Открыть"' : '') + '></div>';
    },
    label: function (b, text, kind, pos, icon) {
      var s;
      if (pos === 'below') s = 'left:' + pctS(b.x) + ';top:calc(' + pctS(b.y + b.h) + ' + 6px)';
      else if (pos === 'left') s = 'right:calc(' + pctS(100 - b.x) + ' + 6px);top:calc(' + pctS(b.y) + ' + 6px)';
      else if (pos === 'right') s = 'left:calc(' + pctS(b.x + b.w) + ' + 6px);top:' + pctS(b.y);
      else if (pos === 'edge') s = 'left:calc(' + pctS(b.x) + ' + 10px);top:calc(' + pctS(b.y + b.h) + ' - 13px)';
      else if (pos === 'above-r') s = 'right:' + pctS(100 - b.x - b.w) + ';top:calc(' + pctS(b.y) + ' - 32px)';
      else s = 'left:' + pctS(b.x) + ';top:calc(' + pctS(b.y) + ' - 32px)';
      return '<span class="ar-label' + (kind && kind !== 'part' ? ' ' + kind : '') + '" style="' + s + '">' + (icon ? KV.icon(icon, 14) : '') + KV.esc(text) + '</span>';
    }
  };
  KV.ROLES = {
    engineer: { label: 'Инженер', person: 'engineer' },
    master: { label: 'Мастер', person: 'master' },
    operator: { label: 'Оператор', person: 'operator' },
    admin: { label: 'Админ', person: 'admin' },
    sec: { label: 'Админ ИБ', person: 'sec' },
    all: { label: 'Все роли', person: null }
  };
  KV.TABS = {
    engineer: [
      { key: 'objects', icon: 'grid', label: 'Объекты', go: 'objects' },
      { key: 'history', icon: 'clock', label: 'История', go: 'history' },
      { key: 'scan', icon: 'scan', label: 'Сканер', go: 'scanner', center: true },
      { key: 'assistant', icon: 'chat', label: 'Ассистент', go: 'assistant' },
      { key: 'profile', icon: 'user', label: 'Профиль', go: 'profile' }
    ],
    master: [
      { key: 'shift', icon: 'clipboard', label: 'Смена', go: 'master-shift' },
      { key: 'findings', icon: 'alertCircle', label: 'Находки', go: 'master-findings', badge: 2 },
      { key: 'scan', icon: 'scan', label: 'Сканер', go: 'scanner', center: true },
      { key: 'plan', icon: 'calendar', label: 'План ТО', go: 'master-plan' },
      { key: 'profile', icon: 'user', label: 'Профиль', go: 'master-profile' }
    ],
    operator: [
      { key: 'objects', icon: 'grid', label: 'Объекты', go: 'op-objects' },
      { key: 'history', icon: 'clock', label: 'История', go: 'op-history' },
      { key: 'report', icon: 'megaphone', label: 'Сообщить', go: 'op-report', center: true },
      { key: 'assistant', icon: 'chat', label: 'Ассистент', go: 'op-assistant' },
      { key: 'profile', icon: 'user', label: 'Профиль', go: 'op-profile' }
    ],
    admin: [
      { key: 'system', icon: 'server', label: 'Система', go: 'adm-system' },
      { key: 'sources', icon: 'plug', label: 'Источники', go: 'adm-sources' },
      { key: 'models', icon: 'cpu', label: 'Модели', go: 'adm-models' },
      { key: 'log', icon: 'list', label: 'Журнал', go: 'adm-log' },
      { key: 'profile', icon: 'user', label: 'Профиль', go: 'adm-profile' }
    ],
    sec: [
      { key: 'users', icon: 'users', label: 'Пользователи', go: 'sec-users' },
      { key: 'roles', icon: 'key', label: 'Роли', go: 'sec-roles' },
      { key: 'log', icon: 'list', label: 'Журнал', go: 'sec-log' },
      { key: 'policy', icon: 'shield', label: 'Политика', go: 'sec-policy' },
      { key: 'profile', icon: 'user', label: 'Профиль', go: 'sec-profile' }
    ]
  };
  KV.tabbar = function (role, active) {
    var tabs = KV.TABS[role];
    if (!tabs) return '';
    return '<nav class="tabbar">' + tabs.map(function (t) {
      var on = t.key === active;
      var a = on ? 'data-toggle="tab-active"' : KV.act({ go: t.go, nav: t.center ? 'up' : 'tab' });
      return '<button class="tab-item' + (t.center ? ' center' : '') + (on ? ' is-on' : '') + '" ' + a + ' aria-label="' + KV.esc(t.label) + '">' + KV.icon(t.icon, t.center ? 26 : 24) +
        (t.badge && !on ? KV.badge(null) : '') + '</button>';
    }).join('') + '</nav>';
  };
  function smooth01(e0, e1, x) { var t = Math.max(0, Math.min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t); }
  KV.level = function (v, warn, alarm, band) {
    var l = 0;
    if (warn != null) l += smooth01(warn - band, warn + band, v);
    if (alarm != null) l += smooth01(alarm - band, alarm + band, v);
    return l;
  };
  KV.levelColor = function (l) {
    if (l <= 0.001) return 'var(--chart-ok)';
    if (l < 0.999) return 'color-mix(in srgb, var(--chart-warn) ' + Math.round(l * 100) + '%, var(--chart-ok))';
    if (l <= 1.001) return 'var(--chart-warn)';
    if (l < 1.999) return 'color-mix(in srgb, var(--chart-alarm) ' + Math.round((l - 1) * 100) + '%, var(--chart-warn))';
    return 'var(--chart-alarm)';
  };
  KV.statusOf = function (v, warn, alarm) { return alarm != null && v > alarm ? 'bad' : warn != null && v > warn ? 'warn' : 'ok'; };
  function bounds(o) {
    var vs = o.values;
    var lo = Math.min.apply(null, vs), hi = Math.max.apply(null, vs);
    if (o.setpoints !== false) {
      if (o.warn != null) { lo = Math.min(lo, o.warn); hi = Math.max(hi, o.warn); }
      if (o.alarm != null && o.alarm < hi * 1.6) hi = Math.max(hi, o.alarm);
    }
    var mid = (hi + lo) / 2, minSpan = Math.abs(mid) * (o.minSpan || 0.18) || 1;
    if (hi - lo < minSpan) { lo = mid - minSpan / 2; hi = mid + minSpan / 2; }
    var pad = (hi - lo) * 0.12 || 1;
    return { min: o.min != null ? o.min : lo - pad, max: o.max != null ? o.max : hi + pad };
  }
  function pathOf(pts) {
    var d = 'M' + pts[0][0].toFixed(1) + ' ' + pts[0][1].toFixed(1);
    for (var i = 0; i < pts.length - 1; i++) {
      var p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
      var c1x = p1[0] + (p2[0] - p0[0]) / 6, c1y = p1[1] + (p2[1] - p0[1]) / 6;
      var c2x = p2[0] - (p3[0] - p1[0]) / 6, c2y = p2[1] - (p3[1] - p1[1]) / 6;
      d += 'C' + c1x.toFixed(1) + ' ' + c1y.toFixed(1) + ' ' + c2x.toFixed(1) + ' ' + c2y.toFixed(1) + ' ' + p2[0].toFixed(1) + ' ' + p2[1].toFixed(1);
    }
    return d;
  }
  function gradStops(vals, warn, alarm, band) {
    var n = vals.length, step = Math.max(1, Math.floor(n / 90)), s = '';
    for (var i = 0; i < n; i += step) {
      s += '<stop offset="' + (i / (n - 1)).toFixed(4) + '" style="stop-color:' + KV.levelColor(KV.level(vals[i], warn, alarm, band)) + '"/>';
    }
    if ((n - 1) % step) s += '<stop offset="1" style="stop-color:' + KV.levelColor(KV.level(vals[n - 1], warn, alarm, band)) + '"/>';
    return s;
  }
  KV.areaChart = function (o) {
    var W = 1000, H = o.height || 200, vals = o.values, n = vals.length;
    var b = bounds(o), band = (b.max - b.min) * 0.035;
    var X = function (i) { return (i / (n - 1)) * W; };
    var Y = function (v) { return 6 + (1 - (v - b.min) / (b.max - b.min)) * (H - 12); };
    var pts = vals.map(function (v, i) { return [X(i), Y(v)]; });
    var line = pathOf(pts);
    var area = line + 'L' + W + ' ' + H + 'L0 ' + H + 'Z';
    var g = KV.uid('g'), f = KV.uid('f'), m = KV.uid('m'), sp = KV.uid('p'), sf = KV.uid('s'), sm = KV.uid('n');
    var stripes = o.stripes !== false;
    var pw = Math.max(8, W / Math.min(n, 70));
    var svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none" aria-hidden="true"><defs>' +
      '<linearGradient id="' + g + '" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="' + W + '" y2="0">' + gradStops(vals, o.warn, o.alarm, band) + '</linearGradient>' +
      '<linearGradient id="' + f + '" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="' + H + '"><stop offset="0" stop-color="#fff" stop-opacity="' + (stripes ? .22 : .30) + '"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>' +
      '<mask id="' + m + '" maskUnits="userSpaceOnUse" x="0" y="0" width="' + W + '" height="' + H + '"><rect width="' + W + '" height="' + H + '" fill="url(#' + f + ')"/></mask>' +
      (stripes ? '<linearGradient id="' + sf + '" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="' + H + '"><stop offset="0" stop-color="#fff" stop-opacity=".62"/><stop offset="1" stop-color="#fff" stop-opacity=".06"/></linearGradient>' +
        '<pattern id="' + sp + '" patternUnits="userSpaceOnUse" width="' + pw.toFixed(2) + '" height="' + H + '"><rect x="0" y="0" width="' + (pw * 0.42).toFixed(2) + '" height="' + H + '" fill="url(#' + sf + ')"/></pattern>' +
        '<mask id="' + sm + '" maskUnits="userSpaceOnUse" x="0" y="0" width="' + W + '" height="' + H + '"><rect width="' + W + '" height="' + H + '" fill="url(#' + sp + ')"/></mask>' : '') +
      '</defs>';
    if (o.setpoints !== false) {
      if (o.warn != null && o.warn < b.max) svg += '<line x1="0" x2="' + W + '" y1="' + Y(o.warn).toFixed(1) + '" y2="' + Y(o.warn).toFixed(1) + '" stroke="var(--chart-warn)" stroke-width="1.4" stroke-dasharray="5 5" vector-effect="non-scaling-stroke" opacity=".9"/>';
      if (o.alarm != null && o.alarm < b.max) svg += '<line x1="0" x2="' + W + '" y1="' + Y(o.alarm).toFixed(1) + '" y2="' + Y(o.alarm).toFixed(1) + '" stroke="var(--chart-alarm)" stroke-width="1.4" stroke-dasharray="5 5" vector-effect="non-scaling-stroke" opacity=".9"/>';
    }
    svg += '<g class="chart-fill"><path d="' + area + '" fill="url(#' + g + ')" mask="url(#' + m + ')"/>' + (stripes ? '<path d="' + area + '" fill="url(#' + g + ')" mask="url(#' + sm + ')"/>' : '') + '</g>' +
      '<path class="chart-stroke" d="' + line + '" fill="none" stroke="url(#' + g + ')" stroke-width="' + (o.strokeWidth || 2.6) + '" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke"/></svg>';
    var last = vals[n - 1], lastY = Y(last) / H * 100;
    var lastCol = KV.levelColor(KV.level(last, o.warn, o.alarm, band));
    var dot = o.dot === false ? '' : '<span class="chart-dot" style="left:100%;top:' + lastY.toFixed(2) + '%;border-color:' + lastCol + '"></span>';
    var bub = '';
    if (o.bubble) {
      var txt = o.bubble === true ? KV.num(last, o.digits == null ? 1 : o.digits) + (o.unit ? ' ' + o.unit : '') : o.bubble;
      bub = '<span class="chart-bubble" style="left:100%;top:' + lastY.toFixed(2) + '%">' + KV.esc(txt) + '</span>';
    }
    var axis = o.labels ? '<div class="chart-axis">' + o.labels.map(function (l) { return '<span>' + KV.esc(l) + '</span>'; }).join('') + '</div>' : '';
    var legend = '';
    if (o.legend) {
      var items = Array.isArray(o.legend) ? o.legend : [
        ['var(--chart-ok)', 'норма'],
        o.warn != null ? ['var(--chart-warn)', 'выше ' + KV.num(o.warn, o.digits == null ? 1 : o.digits)] : null,
        o.alarm != null ? ['var(--chart-alarm)', 'выше ' + KV.num(o.alarm, o.digits == null ? 1 : o.digits) + (o.unit ? ' ' + o.unit : '')] : null
      ].filter(Boolean);
      legend = '<div class="chart-legend">' + items.map(function (it) { return '<span><i class="dot" style="background:' + it[0] + '"></i>' + KV.esc(it[1]) + '</span>'; }).join('') + '</div>';
    }
    return '<div class="chart chart-anim" style="height:' + H + 'px">' + svg + dot + bub + '</div>' + axis + legend;
  };
  KV.sparkline = function (o) {
    return KV.areaChart({ values: o.values, warn: o.warn, alarm: o.alarm, min: o.min, max: o.max, height: o.height || 36, minSpan: o.minSpan || 0.1, stripes: false, setpoints: false, dot: false, strokeWidth: 2.2 });
  };
  KV.bars = function (o) {
    var max = o.max || Math.max.apply(null, o.items.map(function (i) { return i.value; }));
    return '<div class="bars" style="height:' + (o.height || 150) + 'px">' + o.items.map(function (it, i) {
      return '<div class="bar' + (it.hl ? ' is-hl' : '') + '" style="--i:' + i + '"><b>' + KV.num(it.value, o.digits || 0) + '</b><i style="height:' + Math.max(4, it.value / max * 100 * 0.78).toFixed(1) + '%"></i><span>' + KV.esc(it.label) + '</span></div>';
    }).join('') + '</div>';
  };
  KV.screen = function (def) {
    if (!def || !def.id) throw new Error('KV.screen: id required');
    if (KV.screens[def.id]) console.warn('KV.screen: duplicate id ' + def.id);
    def.order = def.order == null ? 100 : def.order;
    def.role = def.role || 'all';
    KV.screens[def.id] = def;
    return def;
  };
  KV.flow = function (f) { KV.flows.push(f); return f; };
  KV.SECTIONS = [
    { id: 'entry', title: 'Вход и первый запуск', sub: 'Общие экраны для всех ролей' },
    { id: 'eng-inspect', title: 'Инженер: осмотр', sub: 'Объекты, карточка агрегата, сканер, диагностика' },
    { id: 'eng-service', title: 'Инженер: итоги и сервис', sub: 'Итоги осмотра, история, ассистент, профиль и настройки' },
    { id: 'master', title: 'Мастер', sub: 'Смена, находки, план ТО, режимы агрегатов' },
    { id: 'operator', title: 'Оператор', sub: 'Состояние агрегатов и сообщение о неисправности' },
    { id: 'admin', title: 'Админ', sub: 'Цеховой сервер, источники данных, модели, журнал' },
    { id: 'sec', title: 'Админ ИБ', sub: 'Учётные записи, роли и права, политика, журнал безопасности' },
    { id: 'flows', title: 'Взаимодействие ролей', sub: 'Сценарии от действия одной роли до результата у другой', kind: 'flows' },
    { id: 'dark', title: 'Тёмная тема', sub: 'Ключевые экраны всех ролей; тема переключается в настройках или следует системе', kind: 'dark' },
    { id: 'adaptive', title: 'Адаптивность', sub: 'Одни и те же экраны на телефонах 360 × 780, 390 × 844 и 430 × 932', kind: 'adaptive' },
    { id: 'components', title: 'Компоненты', sub: 'Библиотека интерфейса в светлой и тёмной теме', kind: 'components' }
  ];
  KV.DARK_SCREENS = ['login', 'objects', 'card', 'card-charts', 'scanner', 'diagnostics', 'assistant', 'master-shift', 'd-m-finding', 'op-objects', 'adm-system', 'sec-users'];
  KV.ADAPTIVE_SCREENS = ['login', 'objects', 'card', 'card-charts'];
  KV.SIZES = [{ w: 360, h: 780 }, { w: 390, h: 844 }, { w: 430, h: 932 }];
})();
