/**
 * Пульт демонстрации «КСТ Визор»: вход, оборудование, показания датчиков, сценарии и время,
 * текущий диагноз с основаниями, история осмотров с отчётами и доска замечаний.
 * Работает только с тем сервером, с которого открыта страница; внешние адреса не используются.
 */
"use strict";

const LIVE_PERIOD_MS = 2000;
const SLOW_PERIOD_MS = 6000;
const REQUEST_TIMEOUT_MS = 10000;
const ALERT_LIFETIME_MS = 9000;
const HOUR_MS = 3600000;
const DAY_MS = 24 * HOUR_MS;
const PLAY_STEP_HOURS = 1;
const SESSION_KEY = "kst-vizor-panel-session";
const DEMO_PASSWORD = "demo12345";
const PERMISSION = {
  panel: "equipment.view",
  control: "telemetry.control",
  confirm: "findings.confirm",
  findings: "findings.view",
  assistant: "assistant.use",
};
const DEFAULT_PARAM = "vib_rms";
const WHOLE_UNIT = "Агрегат в целом";
const NO_LINK = "Нет связи с сервером";

const STATUS_SHORT = {ok: "Замечаний нет", check: "Нужна проверка", defect: "Признаки дефекта", unknown: "Нет данных"};
const STATUS_FULL = {
  ok: "Видимых проблем не обнаружено",
  check: "Рекомендуется проверка",
  defect: "Обнаружены признаки возможного дефекта",
  unknown: "Недостаточно данных для оценки",
};
const STATUS_NOTE = {
  ok: "Это не является подтверждением исправности.",
  unknown: "Датчиков и отметок осмотра не хватает, чтобы оценить состояние.",
};
const FINDING_STATUS = {ok: "Без замечаний", check: "Проверка", defect: "Дефект"};
const SEVERITY = {1: "наблюдение и проверка", 2: "устранить в плановом порядке", 3: "критично"};
const SOURCES = {camera: "Камера", sensor: "Датчики", resource: "Ресурс", manual: "Инженер"};
const MODES = {running: "В работе", stopped: "Остановлен"};
const INSPECTION_STATUS = {active: "Идёт", finished: "Завершён"};
const WORK_KINDS = {checked: "Проверка узла", maintenance: "Техническое обслуживание", replacement: "Замена узла"};
const NEXT_STATE = {open: "in_work", in_work: "resolved"};
const NEXT_STATE_ACTION = {open: "Взять в работу", in_work: "Отметить устранённым"};
const ORIGINS = {customer: "данные заказчика", model: "модель"};
const LEVELS = {ok: "ok", normal: "ok", warn: "warn", warning: "warn", check: "warn", alarm: "alarm", defect: "alarm"};
const GROUPS = [
  {title: "Вибрация", prefixes: ["vib_"]},
  {title: "Температура", prefixes: ["temp_"]},
  {title: "Электрическая часть", prefixes: ["current_", "power"]},
  {title: "Гидравлика", prefixes: ["press_", "flow", "efficiency"]},
  {title: "Режим работы", prefixes: [""]},
];

const state = {
  session: null,
  units: [],
  unitStatus: {},
  unitId: null,
  card: null,
  telemetry: null,
  telemetryMissing: false,
  telemetryReason: "",
  scenarios: [],
  scenariosLoading: null,
  diagnosis: null,
  paramCode: DEFAULT_PARAM,
  hours: 24,
  chart: {key: "", points: [], end: null, hover: null},
  boardScope: "unit",
  playing: false,
  controlBusy: false,
  liveBusy: false,
  liveAgain: false,
  slowBusy: false,
  signatures: {},
  timers: [],
  photoUrl: null,
};

let refreshing = null;
const dom = {};

/** Ошибка обращения к серверу: текст для показа на русском и код ответа (0 - связи нет). */
class ApiError extends Error {
  /** Запоминает текст ошибки и код ответа сервера. */
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

/** Создаёт элемент страницы: свойства задаются объектом, текст вставляется безопасно, без разметки. */
function el(tag, props = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === null || value === undefined || value === false) {
      continue;
    }
    if (key === "class") {
      node.className = value;
    } else if (key === "text") {
      node.textContent = value;
    } else if (key === "on") {
      for (const [name, handler] of Object.entries(value)) {
        node.addEventListener(name, handler);
      }
    } else {
      node.setAttribute(key, value === true ? "" : String(value));
    }
  }
  for (const child of [].concat(children)) {
    if (child !== null && child !== undefined && child !== false) {
      node.append(child);
    }
  }
  return node;
}

/** Превращает значение в число; пустое, нечисловое и бесконечное значение даёт null. */
function toNumber(value) {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) {
    return Number(value);
  }
  return null;
}

/** Дополняет число нулём слева до двух знаков. */
function pad(value) {
  return String(value).padStart(2, "0");
}

/**
 * Разбирает отметку времени сервера «ГГГГ-ММ-ДДTЧЧ:ММ:СС» в миллисекунды.
 * Время стенда не привязано к часовому поясу, поэтому считается как есть, без пересчёта в местное.
 */
function parseStamp(text) {
  const parts = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(String(text || ""));
  if (!parts) {
    return null;
  }
  return Date.UTC(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3]), Number(parts[4] || 0),
    Number(parts[5] || 0), Number(parts[6] || 0));
}

/** Записывает время в виде, который принимает сервер: «ГГГГ-ММ-ДДTЧЧ:ММ:СС». */
function isoStamp(ms) {
  const date = new Date(ms);
  return `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`
    + `T${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())}`;
}

/** Показывает дату как «ДД.ММ.ГГГГ», при необходимости с временем «ЧЧ:ММ». */
function showDate(ms, withTime = true) {
  if (ms === null || ms === undefined) {
    return "нет данных";
  }
  const date = new Date(ms);
  const day = `${pad(date.getUTCDate())}.${pad(date.getUTCMonth() + 1)}.${date.getUTCFullYear()}`;
  return withTime ? `${day} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}` : day;
}

/** Короткая дата «ДД.ММ» для шкал и подписей сценариев. */
function showDay(ms) {
  const date = new Date(ms);
  return `${pad(date.getUTCDate())}.${pad(date.getUTCMonth() + 1)}`;
}

/** Показывает отметку времени сервера по-русски; пустая отметка даёт «нет данных». */
function showStamp(text, withTime = true) {
  return showDate(parseStamp(text), withTime);
}

/** Время на часах этого компьютера «ЧЧ:ММ:СС» - для отметки последнего обновления. */
function clockNow() {
  const date = new Date();
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

/** Форматирует число по-русски: запятая в дробной части, число знаков зависит от величины. */
function formatNumber(value, digits) {
  if (value === null || value === undefined) {
    return "нет данных";
  }
  let places = digits;
  if (places === undefined) {
    const size = Math.abs(value);
    places = size >= 1000 ? 0 : size >= 100 ? 1 : 2;
  }
  return value.toLocaleString("ru-RU", {minimumFractionDigits: 0, maximumFractionDigits: places});
}

/** Число с единицей измерения через пробел. */
function withUnit(value, unit, digits) {
  const text = formatNumber(value, digits);
  return unit && value !== null && value !== undefined ? `${text} ${unit}` : text;
}

/** Длительность в секундах словами: «45 с», «12 мин», «1 ч 05 мин». */
function showDuration(seconds) {
  const total = toNumber(seconds);
  if (total === null) {
    return "";
  }
  if (total < 60) {
    return `${Math.round(total)} с`;
  }
  const minutes = Math.round(total / 60);
  return minutes < 60 ? `${minutes} мин` : `${Math.floor(minutes / 60)} ч ${pad(minutes % 60)} мин`;
}

/** Читает сохранённую сессию из хранилища вкладки; недоступное хранилище не считается ошибкой. */
function readStoredSession() {
  try {
    const saved = JSON.parse(window.sessionStorage.getItem(SESSION_KEY) || "null");
    return saved && saved.access && saved.refresh ? saved : null;
  } catch (error) {
    return null;
  }
}

/** Запоминает токены и пользователя из ответа сервера на вход или обновление. */
function storeSession(reply) {
  state.session = {access: reply.access_token, refresh: reply.refresh_token, user: reply.user};
  saveSession();
}

/** Записывает текущую сессию в хранилище вкладки; без хранилища сессия живёт только в памяти страницы. */
function saveSession() {
  try {
    window.sessionStorage.setItem(SESSION_KEY, JSON.stringify(state.session));
  } catch (error) {
    state.session.volatile = true;
  }
}

/** Завершает сессию: стирает токены, останавливает обновление и показывает вход с пояснением. */
function endSession(message) {
  state.session = null;
  try {
    window.sessionStorage.removeItem(SESSION_KEY);
  } catch (error) {
    state.session = null;
  }
  stopTimers();
  setPlaying(false);
  dom.app.hidden = true;
  dom.login.hidden = false;
  dom.passwordForm.hidden = true;
  dom.loginForm.hidden = false;
  dom.loginError.hidden = !message;
  dom.loginError.textContent = message || "";
  dom.loginPassword.value = "";
}

/** Собирает русский текст ошибки из ответа сервера: его пояснение или описание по коду. */
async function errorText(response) {
  let detail = null;
  try {
    detail = (await response.json()).detail;
  } catch (error) {
    detail = null;
  }
  if (typeof detail === "string" && detail.trim()) {
    return detail;
  }
  const known = {
    400: "Запрос отклонён сервером",
    401: "Нужно войти заново",
    403: "Недостаточно прав для этого действия",
    404: "Запрошенные данные не найдены на сервере",
    409: "Действие сейчас невозможно: данные уже изменились",
    422: "Сервер не принял запрос: проверьте введённые данные",
    429: "Слишком много попыток - подождите и повторите",
    503: "Служба временно недоступна",
  };
  return known[response.status] || `Ошибка сервера, код ${response.status}`;
}

/** Выполняет один сетевой запрос с ограничением по времени; обрыв связи превращает в ApiError с кодом 0. */
async function send(method, path, options, token) {
  const headers = {};
  let body;
  if (options.form) {
    body = options.form;
  } else if (options.json !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(options.json);
  }
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  const abort = new AbortController();
  const timer = window.setTimeout(() => abort.abort(), REQUEST_TIMEOUT_MS);
  try {
    return await fetch(path, {method, headers, body, signal: abort.signal, cache: "no-store"});
  } catch (error) {
    throw new ApiError(NO_LINK, 0);
  } finally {
    window.clearTimeout(timer);
  }
}

/** Меняет пару токенов на новую; отказ сервера завершает сессию. */
async function refreshTokens() {
  const refresh = state.session ? state.session.refresh : null;
  if (!refresh) {
    throw new ApiError("Нужно войти заново", 401);
  }
  const response = await send("POST", "/auth/refresh", {json: {refresh_token: refresh}}, null);
  if (!response.ok) {
    endSession("Сессия завершена - войдите снова");
    throw new ApiError("Сессия завершена - войдите снова", 401);
  }
  storeSession(await response.json());
}

/**
 * Обновляет токен доступа после ответа 401. Обновление всегда одно на все ожидающие запросы:
 * сервер отзывает сессию, если один и тот же токен обновления предъявлен дважды.
 */
async function renewAccess(usedToken) {
  if (state.session && state.session.access !== usedToken) {
    return;
  }
  if (!refreshing) {
    refreshing = refreshTokens().finally(() => {
      refreshing = null;
    });
  }
  await refreshing;
}

/**
 * Обращается к серверу от имени вошедшего пользователя и возвращает разобранный ответ.
 * options: json - тело запроса, form - форма, blob - вернуть файл, open - запрос без токена.
 */
async function request(method, path, options = {}) {
  const token = !options.open && state.session ? state.session.access : null;
  let response = await send(method, path, options, token);
  if (response.status === 401 && token) {
    await renewAccess(token);
    response = await send(method, path, options, state.session ? state.session.access : null);
  }
  if (!response.ok) {
    throw new ApiError(await errorText(response), response.status);
  }
  if (options.blob) {
    return response.blob();
  }
  try {
    return await response.json();
  } catch (error) {
    throw new ApiError("Сервер прислал ответ в неожиданном виде", response.status);
  }
}

/** Адрес раздела API для выбранного агрегата. */
function unitPath(unitId, tail = "") {
  return `/equipment/${encodeURIComponent(unitId)}${tail}`;
}

/** Показывает всплывающее сообщение; одинаковые сообщения не дублируются, обычные исчезают сами. */
function notify(message, kind = "error", sticky = false) {
  for (const shown of dom.alerts.children) {
    if (shown.dataset.message === message) {
      return shown;
    }
  }
  const box = el("div", {class: kind === "notice" ? "alert notice" : "alert", "data-message": message}, [
    el("p", {text: message}),
    el("button", {type: "button", "aria-label": "Закрыть сообщение", text: "×", on: {click: () => box.remove()}}),
  ]);
  dom.alerts.append(box);
  if (!sticky) {
    window.setTimeout(() => box.remove(), ALERT_LIFETIME_MS);
  }
  return box;
}

/** Отмечает, что сервер ответил: убирает сообщение об обрыве связи и обновляет отметку времени. */
function markOnline() {
  if (state.offlineBox) {
    state.offlineBox.remove();
    state.offlineBox = null;
  }
  state.offlineSince = null;
  dom.linkState.className = "link-state online";
  dom.linkState.textContent = `Данные обновлены в ${clockNow()}`;
}

/** Отмечает обрыв связи: постоянное сообщение на экране до первого удачного ответа. */
function markOffline() {
  if (!state.offlineSince) {
    state.offlineSince = clockNow();
  }
  dom.linkState.className = "link-state offline";
  dom.linkState.textContent = `Нет связи с сервером с ${state.offlineSince}`;
  if (!state.offlineBox || !state.offlineBox.isConnected) {
    state.offlineBox = notify(
      `Нет связи с сервером с ${state.offlineSince}. Данные на экране не обновляются, попытки продолжаются.`,
      "error", true);
  }
}

/** Показывает или убирает сообщение об ошибке внутри раздела страницы. */
function setSectionError(section, message) {
  const box = document.getElementById(`err-${section}`);
  if (box) {
    box.hidden = !message;
    box.textContent = message || "";
  }
}

/**
 * Выполняет загрузку данных раздела. При неудаче пишет видимое сообщение (в разделе или об обрыве связи)
 * и возвращает undefined, чтобы остальные разделы продолжали обновляться.
 */
async function load(section, label, job) {
  try {
    const result = await job();
    setSectionError(section, "");
    markOnline();
    return result;
  } catch (error) {
    if (!state.session) {
      return undefined;
    }
    if (error instanceof ApiError && error.status === 0) {
      markOffline();
    } else {
      const reason = error instanceof ApiError ? error.message : "страница не смогла разобрать ответ сервера";
      setSectionError(section, `${label}: ${reason}`);
    }
    return undefined;
  }
}

/** Перерисовывает раздел только при изменении данных, чтобы раскрытые блоки и фокус не сбрасывались. */
function renderIfChanged(key, data, draw) {
  const signature = JSON.stringify(data === undefined ? null : data);
  if (state.signatures[key] === signature) {
    return;
  }
  state.signatures[key] = signature;
  draw();
}

/** Есть ли у вошедшего пользователя право с этим кодом: права приходят от сервера при входе и обновлении. */
function can(permission) {
  const user = state.session ? state.session.user : null;
  return Boolean(user && Array.isArray(user.permissions) && user.permissions.includes(permission));
}

/** Может ли вошедший пользователь переключать сценарии и время стенда. */
function canControl() {
  return can(PERMISSION.control);
}

/** Может ли вошедший пользователь переводить замечания по состояниям. */
function canConfirm() {
  return can(PERMISSION.confirm);
}

/** Запись выбранного агрегата из списка оборудования. */
function currentUnit() {
  return state.units.find((unit) => unit.id === state.unitId) || null;
}

/** Есть ли у выбранного агрегата телеметрия (по карточке и по ответу сервера). */
function hasTelemetry() {
  const unit = currentUnit();
  return Boolean(unit) && unit.telemetry !== false && !state.telemetryMissing;
}

/** Название узла по его коду из карточки агрегата. */
function nodeName(code) {
  if (!code || code === "equipment") {
    return WHOLE_UNIT;
  }
  const nodes = state.card && Array.isArray(state.card.nodes) ? state.card.nodes : [];
  const found = nodes.find((node) => node.code === code || node.id === code);
  return found ? found.name : code;
}

/** Определяет уровень показания: готовый от сервера или по уставкам и направлению отклонения. */
function levelOf(given, value, warn, alarm, direction) {
  if (LEVELS[given]) {
    return LEVELS[given];
  }
  if (value === null || !direction || (warn === null && alarm === null)) {
    return "plain";
  }
  const beyond = (limit) => limit !== null && (direction === "low" ? value < limit : value > limit);
  if (beyond(alarm)) {
    return "alarm";
  }
  return beyond(warn) ? "warn" : "ok";
}

/** Читает границы времени из ответа сервера: пара значений или объект с началом и концом. */
function readBounds(raw) {
  if (Array.isArray(raw)) {
    return [parseStamp(raw[0]), parseStamp(raw[1])];
  }
  if (raw && typeof raw === "object") {
    return [parseStamp(raw.first || raw.start || raw.from || raw.min),
      parseStamp(raw.last || raw.end || raw.to || raw.max)];
  }
  return [null, null];
}

/** Приводит ответ с показаниями к одному виду: время, границы записи, параметры с уровнями, диагнозы заказчика. */
function normalizeTelemetry(raw) {
  const data = raw && typeof raw === "object" ? raw : {};
  const values = data.snapshot || data.values || data.readings || {};
  const statuses = data.statuses || data.levels || {};
  let list = Array.isArray(data.parameters) ? data.parameters : Array.isArray(data.params) ? data.params : [];
  if (!list.length) {
    list = Object.keys(values).map((code) => ({code}));
  }
  const params = [];
  for (const item of list) {
    if (!item || typeof item.code !== "string") {
      continue;
    }
    const value = toNumber(item.value !== undefined ? item.value : values[item.code]);
    const warn = toNumber(item.warn);
    const alarm = toNumber(item.alarm);
    const direction = item.direction === "high" || item.direction === "low" ? item.direction : null;
    const given = item.level || item.status || item.state || statuses[item.code];
    params.push({
      code: item.code, name: item.name || item.code, unit: item.unit || "", warn, alarm, direction, value,
      source: item.source || null, basis: item.basis || "", level: levelOf(given, value, warn, alarm, direction),
    });
  }
  const labels = data.labels && typeof data.labels === "object" ? data.labels : {};
  const [first, last] = readBounds(data.bounds);
  return {
    available: data.available !== false,
    reason: typeof data.reason === "string" ? data.reason : "",
    cursor: parseStamp(data.cursor || data.at || data.time), first, last,
    customerLast: parseStamp(data.customer_until),
    params,
    labels: {vibration: readLabel(labels.vibration), temperature: readLabel(labels.temperature)},
  };
}

/**
 * Читает диагноз по вибрации или температуре: сервер присылает {text, source}, где source "customer" -
 * запись из базы заказчика, "model" - диагноз, посчитанный по тем же уставкам на модельных часах.
 */
function readLabel(raw) {
  if (typeof raw === "string") {
    return {text: raw, source: "customer"};
  }
  if (raw && typeof raw === "object" && typeof raw.text === "string") {
    return {text: raw.text, source: raw.source === "model" ? "model" : "customer"};
  }
  return null;
}

/** Приводит ряд значений параметра к списку точек {at, value}, упорядоченному по времени. */
function normalizeSeries(raw) {
  const list = Array.isArray(raw) ? raw : (raw && (raw.points || raw.values || raw.window || raw.data)) || [];
  const points = [];
  for (const item of Array.isArray(list) ? list : []) {
    let at = null;
    let value = null;
    if (Array.isArray(item)) {
      at = parseStamp(item[0]);
      value = toNumber(item[1]);
    } else if (item && typeof item === "object") {
      at = parseStamp(item.at || item.t || item.time || item.timestamp);
      value = toNumber(item.value !== undefined ? item.value : item.v);
    }
    if (at !== null && value !== null) {
      points.push({at, value});
    }
  }
  points.sort((a, b) => a.at - b.at);
  return points;
}

/** Достаёт список из ответа сервера: сам массив или массив под одним из известных ключей. */
function listFrom(raw, keys) {
  if (Array.isArray(raw)) {
    return raw;
  }
  for (const key of keys) {
    if (raw && Array.isArray(raw[key])) {
      return raw[key];
    }
  }
  return [];
}

/** Приводит ответ с диагнозом к виду {status, findings, nodes}. */
function normalizeDiagnosis(raw) {
  const data = raw && raw.diagnosis && typeof raw.diagnosis === "object" ? raw.diagnosis : raw || {};
  return {
    status: STATUS_FULL[data.status] ? data.status : "unknown",
    findings: Array.isArray(data.findings) ? data.findings : [],
    nodes: data.nodes && typeof data.nodes === "object" ? data.nodes : {},
  };
}

/** Составляет русскую фразу о прогнозе выхода параметра за уставку из ответа сервера. */
function forecastText(raw, param) {
  const data = raw && typeof raw === "object" ? raw : {};
  for (const key of ["text", "message", "summary"]) {
    if (typeof data[key] === "string" && data[key].trim()) {
      return data[key];
    }
  }
  const unit = param ? param.unit : "";
  const parts = [];
  const phrase = (title, hours, threshold) => {
    const limit = threshold !== null ? ` (${withUnit(threshold, unit)})` : "";
    if (hours === 0) {
      return `${title}${limit} уже достигнут`;
    }
    return `до ${title === "уровень тревоги" ? "уровня тревоги" : "уровня предупреждения"}${limit} около ${withUnit(hours, "ч", 1)}`;
  };
  for (const [key, title] of [["warn", "уровень предупреждения"], ["alarm", "уровень тревоги"]]) {
    const part = data[key];
    let hours = null;
    let threshold = param ? param[key] : null;
    if (part && typeof part === "object") {
      hours = toNumber(part.hours !== undefined ? part.hours : part.hours_to_threshold);
      threshold = toNumber(part.threshold) !== null ? toNumber(part.threshold) : threshold;
    } else {
      hours = toNumber(part !== undefined ? part : data[`${key}_hours`] !== undefined ? data[`${key}_hours`] : data[`hours_to_${key}`]);
    }
    if (hours !== null) {
      parts.push(phrase(title, hours, threshold));
    }
  }
  if (!parts.length) {
    const hours = toNumber(data.hours !== undefined ? data.hours : data.hours_to_threshold);
    if (hours !== null) {
      const threshold = toNumber(data.threshold);
      const alarm = param && threshold !== null && threshold === param.alarm;
      parts.push(phrase(alarm ? "уровень тревоги" : "уровень предупреждения", hours, threshold));
    }
  }
  if (!parts.length) {
    return "Прогноз не построен: устойчивого движения к уставке за последние часы нет.";
  }
  return `Прогноз по тренду: ${parts.join("; ")}. Оценка расчётная, решение принимает инженер.`;
}

/** Включает или выключает ход времени; кнопка показывает текущее состояние. */
function setPlaying(playing) {
  state.playing = playing;
  if (dom.play) {
    dom.play.setAttribute("aria-pressed", playing ? "true" : "false");
    dom.play.textContent = playing ? "Остановить время" : "Пустить время: 1 час за 2 секунды";
  }
}

/** Останавливает все периодические обновления. */
function stopTimers() {
  for (const timer of state.timers) {
    window.clearInterval(timer);
  }
  state.timers = [];
}

/** Запускает периодические обновления: живые данные каждые 2 секунды, остальное реже. */
function startTimers() {
  stopTimers();
  state.timers.push(window.setInterval(liveTick, LIVE_PERIOD_MS));
  state.timers.push(window.setInterval(slowTick, SLOW_PERIOD_MS));
  state.timers.push(window.setInterval(playTick, LIVE_PERIOD_MS));
}

/** Загружает показания датчиков выбранного агрегата и обновляет плитки, часы и шкалу времени. */
async function loadTelemetry(unitId) {
  let missing = false;
  const raw = await load("telemetry", "Показания датчиков не получены", async () => {
    try {
      return await request("GET", unitPath(unitId, "/telemetry"));
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) {
        missing = true;
        return null;
      }
      throw error;
    }
  });
  if (unitId !== state.unitId || raw === undefined) {
    return;
  }
  const telemetry = missing ? null : normalizeTelemetry(raw);
  if (missing || !telemetry.available) {
    state.telemetryMissing = true;
    state.telemetryReason = telemetry && telemetry.reason ? telemetry.reason : "";
    state.telemetry = null;
  } else {
    state.telemetryMissing = false;
    state.telemetryReason = "";
    state.telemetry = telemetry;
    if (!state.scenarios.length) {
      loadScenarios(unitId);
    }
    if (!state.telemetry.params.some((param) => param.code === state.paramCode) && state.telemetry.params.length) {
      state.paramCode = state.telemetry.params[0].code;
    }
  }
  renderConsole();
  renderTelemetry();
}

/** Загружает текущий диагноз выбранного агрегата. */
async function loadDiagnosis(unitId) {
  const raw = await load("diagnosis", "Диагноз не получен", () => request("GET", unitPath(unitId, "/diagnosis")));
  if (unitId !== state.unitId || raw === undefined) {
    return;
  }
  state.diagnosis = normalizeDiagnosis(raw);
  state.unitStatus[unitId] = state.diagnosis.status;
  renderDiagnosis();
  renderUnits();
}

/** Загружает ряд выбранного параметра и прогноз, если изменились агрегат, параметр, период или время. */
async function loadChart(unitId) {
  const telemetry = state.telemetry;
  if (!telemetry || !telemetry.params.length) {
    return;
  }
  const key = `${unitId}|${state.paramCode}|${state.hours}|${telemetry.cursor}`;
  if (state.chart.key === key) {
    return;
  }
  const code = encodeURIComponent(state.paramCode);
  const raw = await load("chart", "График не получен",
    () => request("GET", unitPath(unitId, `/telemetry/${code}?hours=${state.hours}`)));
  if (unitId !== state.unitId || raw === undefined) {
    return;
  }
  state.chart = {key, points: normalizeSeries(raw), end: telemetry.cursor, hover: null};
  drawChart();
  const param = selectedParam();
  if (!param || !param.direction) {
    dom.forecast.textContent = "У параметра нет уставок, прогноз не строится.";
    return;
  }
  const forecast = await load("chart", "Прогноз не получен", () => request("GET", unitPath(unitId, `/forecast/${code}`)));
  if (unitId === state.unitId && forecast !== undefined && state.chart.key === key) {
    dom.forecast.textContent = forecastText(forecast, param);
  }
}

/** Один шаг живого обновления: показания, диагноз и график выбранного агрегата. */
async function liveTick() {
  if (!state.session || !state.unitId) {
    return;
  }
  if (state.liveBusy) {
    state.liveAgain = true;
    return;
  }
  state.liveBusy = true;
  const unitId = state.unitId;
  try {
    const jobs = [loadDiagnosis(unitId)];
    const unit = currentUnit();
    if (unit && unit.telemetry !== false) {
      jobs.push(loadTelemetry(unitId).then(() => loadChart(unitId)));
    }
    await Promise.all(jobs);
  } finally {
    state.liveBusy = false;
    if (state.liveAgain) {
      state.liveAgain = false;
      liveTick();
    }
  }
}

/** Загружает список оборудования и выбирает агрегат, если он ещё не выбран. */
async function loadUnits() {
  const raw = await load("units", "Список оборудования не получен", () => request("GET", "/equipment"));
  if (raw === undefined) {
    return;
  }
  state.units = listFrom(raw, ["items", "equipment"]);
  if (!currentUnit() && state.units.length) {
    const preferred = state.units.find((unit) => unit.telemetry) || state.units[0];
    selectUnit(preferred.id);
  }
  renderUnits();
}

/** Узнаёт общий статус остальных агрегатов для списка оборудования. */
async function loadOtherStatuses() {
  const others = state.units.filter((unit) => unit.id !== state.unitId);
  await Promise.all(others.map(async (unit) => {
    try {
      state.unitStatus[unit.id] = normalizeDiagnosis(await request("GET", unitPath(unit.id, "/diagnosis"))).status;
    } catch (error) {
      state.unitStatus[unit.id] = "failed";
    }
  }));
  renderUnits();
}

/** Загружает историю осмотров и работ выбранного агрегата. */
async function loadHistory(unitId) {
  const raw = await load("history", "История не получена", () => request("GET", unitPath(unitId, "/history?limit=50")));
  if (unitId === state.unitId && raw !== undefined) {
    renderIfChanged("history", listFrom(raw, ["items", "history"]), () => renderHistory(listFrom(raw, ["items", "history"])));
  }
}

/** Загружает порядок осмотра узлов выбранного агрегата. */
async function loadRoute(unitId) {
  const raw = await load("route", "Порядок осмотра не получен", () => request("GET", unitPath(unitId, "/route")));
  if (unitId === state.unitId && raw !== undefined) {
    const route = listFrom(raw, ["route", "nodes", "items"]);
    renderIfChanged("route", route, () => renderRoute(route));
  }
}

/** Загружает замечания для доски: по выбранному агрегату или по всему оборудованию. */
async function loadFindings() {
  if (!can(PERMISSION.findings)) {
    setSectionError("findings", "Доска замечаний недоступна: у вашей роли нет права «Просмотр замечаний».");
    return;
  }
  const scope = state.boardScope;
  const unitId = state.unitId;
  const query = scope === "unit" && unitId ? `?limit=200&equipment_id=${encodeURIComponent(unitId)}` : "?limit=200";
  const raw = await load("findings", "Замечания не получены", () => request("GET", `/inspections/findings${query}`));
  if (raw === undefined || scope !== state.boardScope || unitId !== state.unitId) {
    return;
  }
  const findings = listFrom(raw, ["items", "findings"]);
  renderIfChanged("board", {findings, scope, control: canConfirm()}, () => renderBoard(findings));
}

/** Редкое обновление: оборудование, история, порядок осмотра и доска замечаний. */
async function slowTick() {
  if (!state.session || state.slowBusy) {
    return;
  }
  state.slowBusy = true;
  try {
    await loadUnits();
    const unitId = state.unitId;
    if (unitId) {
      await Promise.all([loadHistory(unitId), loadRoute(unitId), loadFindings(), loadOtherStatuses()]);
    }
  } finally {
    state.slowBusy = false;
  }
}

/** Выбирает агрегат: сбрасывает данные прежнего и загружает карточку, сценарии и все разделы. */
function selectUnit(unitId) {
  if (state.unitId === unitId) {
    return;
  }
  state.unitId = unitId;
  state.card = null;
  state.telemetry = null;
  state.telemetryMissing = false;
  state.telemetryReason = "";
  state.scenarios = [];
  state.diagnosis = null;
  state.chart = {key: "", points: [], end: null, hover: null};
  state.signatures = {};
  setPlaying(false);
  for (const section of ["console", "telemetry", "chart", "diagnosis", "route", "history", "findings"]) {
    setSectionError(section, "");
  }
  dom.forecast.textContent = "";
  renderUnits();
  renderConsole();
  renderTelemetry();
  renderDiagnosis();
  renderRoute([]);
  renderHistory(null);
  drawChart();
  loadCard(unitId);
  liveTick();
  loadHistory(unitId);
  loadRoute(unitId);
  loadFindings();
}

/** Загружает карточку агрегата: названия узлов для диагноза, истории и доски. */
async function loadCard(unitId) {
  const card = await load("units", "Карточка оборудования не получена", () => request("GET", unitPath(unitId)));
  if (unitId !== state.unitId) {
    return;
  }
  if (card !== undefined) {
    state.card = card;
    state.signatures.diagnosis = undefined;
    renderDiagnosis();
  }
}

/** Загружает сценарии демонстрации; повторный запрос, пока идёт первый, не отправляется. */
async function loadScenarios(unitId) {
  if (state.scenariosLoading === unitId) {
    return;
  }
  state.scenariosLoading = unitId;
  const raw = await load("console", "Список сценариев не получен", async () => {
    try {
      return await request("GET", unitPath(unitId, "/scenarios"));
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) {
        return [];
      }
      throw error;
    }
  });
  if (state.scenariosLoading === unitId) {
    state.scenariosLoading = null;
  }
  if (unitId === state.unitId && raw !== undefined) {
    state.scenarios = listFrom(raw, ["scenarios", "items"]);
    renderConsole();
  }
}

/**
 * Выполняет действие пульта (сценарий или сдвиг времени): не допускает наложения запросов,
 * показывает отказ сервера и сразу обновляет живые данные.
 */
async function control(job) {
  if (state.controlBusy) {
    return false;
  }
  state.controlBusy = true;
  let done = false;
  try {
    await job();
    markOnline();
    done = true;
  } catch (error) {
    if (error instanceof ApiError && error.status === 0) {
      markOffline();
    } else {
      notify(`Действие не выполнено: ${error instanceof ApiError ? error.message : "ошибка страницы"}`);
    }
  } finally {
    state.controlBusy = false;
  }
  liveTick();
  return done;
}

/** Переводит время стенда на пик выбранного сценария. */
function chooseScenario(scenarioId) {
  setPlaying(false);
  const unitId = state.unitId;
  control(() => request("POST", unitPath(unitId, `/scenarios/${encodeURIComponent(scenarioId)}`)));
}

/** Устанавливает время стенда; значение округляется до часа и удерживается в границах записи. */
function moveCursor(target) {
  const telemetry = state.telemetry;
  if (!telemetry || telemetry.first === null || telemetry.last === null) {
    notify("Время не изменено: сервер не сообщил границы записи телеметрии");
    return Promise.resolve(false);
  }
  const rounded = Math.round(target / HOUR_MS) * HOUR_MS;
  const moment = Math.min(telemetry.last, Math.max(telemetry.first, rounded));
  const unitId = state.unitId;
  return control(() => request("POST", unitPath(unitId, "/cursor"), {json: {at: isoStamp(moment)}}));
}

/** Сдвигает время стенда на заданное число часов от текущего. */
function stepCursor(hours) {
  setPlaying(false);
  if (state.telemetry && state.telemetry.cursor !== null) {
    moveCursor(state.telemetry.cursor + hours * HOUR_MS);
  }
}

/** Шаг хода времени: плюс один час; в конце записи или при отказе сервера ход останавливается. */
async function playTick() {
  const telemetry = state.telemetry;
  if (!state.playing || state.controlBusy || !telemetry || telemetry.cursor === null) {
    return;
  }
  if (telemetry.last !== null && telemetry.cursor >= telemetry.last) {
    setPlaying(false);
    notify("Запись телеметрии закончилась - ход времени остановлен", "notice");
    return;
  }
  const moved = await moveCursor(telemetry.cursor + PLAY_STEP_HOURS * HOUR_MS);
  if (!moved) {
    setPlaying(false);
  }
}

/** Доля положения момента времени на шкале записи, в процентах. */
function stripShare(moment) {
  const telemetry = state.telemetry;
  if (!telemetry || telemetry.first === null || telemetry.last === null || telemetry.last <= telemetry.first) {
    return null;
  }
  const share = (moment - telemetry.first) / (telemetry.last - telemetry.first);
  return Math.min(100, Math.max(0, share * 100));
}

/** Идёт ли сейчас этот сценарий: время стенда внутри эпизода или на опорной точке. */
function scenarioActive(scenario, cursor) {
  if (cursor === null) {
    return false;
  }
  const peak = parseStamp(scenario.peak);
  if (scenario.kind === "reference") {
    return peak === cursor;
  }
  const begin = parseStamp(scenario.onset || scenario.start);
  const end = parseStamp(scenario.end || scenario.peak);
  return begin !== null && end !== null && cursor >= begin && cursor <= end;
}

/** Рисует кнопки сценариев; нажатая кнопка - сценарий, внутри которого сейчас время стенда. */
function renderScenarioButtons() {
  const cursor = state.telemetry ? state.telemetry.cursor : null;
  const allowed = canControl();
  const view = state.scenarios.map((scenario) => ({scenario, active: scenarioActive(scenario, cursor)}));
  renderIfChanged("scenarios", {view, allowed}, () => {
    dom.scenarios.replaceChildren(...view.map(({scenario, active}) => {
      const start = parseStamp(scenario.start || scenario.onset || scenario.peak);
      const end = parseStamp(scenario.end || scenario.peak);
      const span = start === null ? "" : end !== null && showDay(end) !== showDay(start)
        ? `${showDay(start)} - ${showDay(end)}` : showDay(start);
      const origin = ORIGINS[scenario.source] || "";
      const rules = Array.isArray(scenario.expected_rules) && scenario.expected_rules.length
        ? `ожидаемые правила: ${scenario.expected_rules.join(", ")}` : "";
      return el("button", {
        class: "scenario", type: "button", disabled: !allowed, "aria-pressed": active ? "true" : "false",
        title: scenario.description || scenario.title || scenario.id,
        on: {click: () => chooseScenario(scenario.id)},
      }, [
        el("span", {class: "scenario-title", text: scenario.title || scenario.id}),
        el("span", {class: "scenario-meta", text: [span, origin].filter(Boolean).join(", ")}),
        rules ? el("span", {class: "scenario-meta", text: rules}) : null,
      ]);
    }));
  });
}

/** Рисует на шкале времени эпизоды сценариев, границу данных заказчика и подписи дат. */
function renderStrip() {
  const telemetry = state.telemetry;
  const ready = Boolean(telemetry) && stripShare(telemetry.first) !== null;
  const data = ready ? {first: telemetry.first, last: telemetry.last, edge: telemetry.customerLast, scenarios: state.scenarios} : null;
  renderIfChanged("strip", data, () => {
    const bands = [];
    const ticks = [];
    if (ready) {
      for (const scenario of state.scenarios) {
        if (scenario.kind === "reference") {
          continue;
        }
        const onset = parseStamp(scenario.onset || scenario.start);
        const start = parseStamp(scenario.start || scenario.onset);
        const end = parseStamp(scenario.end || scenario.peak);
        if (onset === null || start === null || end === null) {
          continue;
        }
        const model = scenario.source === "model" ? " model" : "";
        const title = `${scenario.title || scenario.id}: ${showDate(onset)} - ${showDate(end)}`;
        const place = (from, to) => `left:${stripShare(from)}%;width:${Math.max(0.3, stripShare(to) - stripShare(from))}%`;
        if (start > onset) {
          bands.push(el("div", {class: `band${model}`, style: place(onset, start), title}));
        }
        bands.push(el("div", {class: `band beyond${model}`, style: place(start, end + HOUR_MS), title}));
      }
      if (telemetry.customerLast !== null && telemetry.customerLast < telemetry.last) {
        bands.push(el("div", {
          class: "band-edge", style: `left:${stripShare(telemetry.customerLast)}%`,
          title: "Конец данных заказчика, дальше смоделированные данные",
        }));
      }
      const days = Math.max(1, Math.round((telemetry.last - telemetry.first) / DAY_MS));
      const every = days > 20 ? 3 : days > 10 ? 2 : 1;
      let index = 0;
      for (let day = Math.ceil(telemetry.first / DAY_MS) * DAY_MS; day <= telemetry.last; day += DAY_MS) {
        if (index % every === 0) {
          ticks.push(el("span", {style: `left:${stripShare(day)}%`, text: showDay(day)}));
        }
        index += 1;
      }
    }
    dom.stripBands.replaceChildren(...bands);
    dom.stripTicks.replaceChildren(...ticks);
  });
  const share = ready && telemetry.cursor !== null ? stripShare(telemetry.cursor) : null;
  dom.stripNeedle.hidden = share === null;
  if (share !== null) {
    dom.stripNeedle.style.left = `${share}%`;
    const hoursTotal = Math.round((telemetry.last - telemetry.first) / HOUR_MS);
    dom.strip.setAttribute("aria-valuemax", String(hoursTotal));
    dom.strip.setAttribute("aria-valuenow", String(Math.round((telemetry.cursor - telemetry.first) / HOUR_MS)));
    dom.strip.setAttribute("aria-valuetext", showDate(telemetry.cursor));
  }
  dom.strip.classList.toggle("locked", !canControl() || !ready);
}

/** Обновляет пульт: агрегат, время стенда, происхождение данных, сценарии, шкалу и доступность кнопок. */
function renderConsole() {
  const unit = currentUnit();
  const telemetry = state.telemetry;
  const hours = telemetry ? telemetry.params.find((param) => param.code === "run_hours") : null;
  const facts = unit ? [unit.name, unit.model] : [];
  if (hours && hours.value !== null) {
    facts.push(`наработка ${withUnit(hours.value, "ч", 0)}`);
  }
  dom.consoleUnit.textContent = facts.filter(Boolean).join(", ");
  const live = hasTelemetry();
  dom.consoleBody.hidden = !live;
  let note = "";
  if (unit && !live) {
    note = unit.telemetry && state.telemetryReason
      ? `Телеметрия агрегата «${unit.name}» недоступна: ${state.telemetryReason}`
      : `К агрегату «${unit.name}» датчики не подключены: сценарии и время действуют только для насоса с телеметрией.`;
  } else if (!canControl()) {
    note = "Сценарии и время переключают роли с правом «Управление лентой телеметрии» - для вашей роли управление отключено.";
  }
  dom.consoleNote.hidden = !note;
  dom.consoleNote.textContent = note;
  dom.cursorTime.textContent = telemetry && telemetry.cursor !== null ? showDate(telemetry.cursor) : "нет данных";
  let origin = "";
  if (telemetry && telemetry.params.some((param) => param.source)) {
    origin = telemetry.params.some((param) => param.source === "customer")
      ? "данные заказчика и модельные каналы" : "смоделированные данные";
  }
  dom.cursorOrigin.textContent = live ? origin : "";
  renderScenarioButtons();
  renderStrip();
  const locked = !canControl() || !telemetry || telemetry.cursor === null;
  for (const button of dom.steps) {
    button.disabled = locked;
  }
  dom.play.disabled = locked;
}

/** Параметр, выбранный для графика. */
function selectedParam() {
  return state.telemetry ? state.telemetry.params.find((param) => param.code === state.paramCode) || null : null;
}

/** Подпись под значением плитки: сравнение с уставками или их отсутствие. */
function tileNote(param) {
  if (param.value === null) {
    return "значение не получено";
  }
  if (!param.direction || (param.warn === null && param.alarm === null)) {
    return "без уставок";
  }
  const side = param.direction === "low" ? "ниже" : "выше";
  if (param.level === "alarm" && param.alarm !== null) {
    return `${side} уровня тревоги ${formatNumber(param.alarm)}`;
  }
  if (param.level === "warn" && param.warn !== null) {
    return `${side} предупреждения ${formatNumber(param.warn)}`;
  }
  const limits = [param.warn, param.alarm].filter((limit) => limit !== null).map((limit) => formatNumber(limit));
  return `уставки ${limits.join(" / ")}`;
}

/** Значение параметра для плитки: режим словами, остальное числом. */
function tileValue(param) {
  if (param.code === "mode" && param.value !== null) {
    return param.value > 0 ? "В работе" : "Остановлен";
  }
  return formatNumber(param.value, param.code === "run_hours" || param.code === "rpm" ? 0 : undefined);
}

/** Строит плитки параметров по группам; вызывается при смене состава параметров. */
function buildTiles(params) {
  const rest = params.slice();
  const blocks = [];
  for (const group of GROUPS) {
    const own = [];
    for (let index = rest.length - 1; index >= 0; index -= 1) {
      if (group.prefixes.some((prefix) => rest[index].code.startsWith(prefix))) {
        own.unshift(rest.splice(index, 1)[0]);
      }
    }
    if (!own.length) {
      continue;
    }
    blocks.push(el("div", {}, [
      el("p", {class: "tile-group-title", text: group.title}),
      el("div", {class: "tile-row"}, own.map((param) => el("button", {
        class: "tile", type: "button", "data-code": param.code,
        on: {click: () => chooseParam(param.code)},
      }, [
        el("span", {class: "tile-name"}),
        el("span", {}, [el("span", {class: "tile-value"}), el("span", {class: "tile-unit"})]),
        el("span", {class: "tile-note"}),
      ]))),
    ]));
  }
  dom.tiles.replaceChildren(...blocks);
}

/** Обновляет плитки показаний и диагнозы заказчика; значения меняются на месте, без перестройки. */
function renderTelemetry() {
  const telemetry = state.telemetry;
  const unit = currentUnit();
  if (!telemetry || !telemetry.params.length) {
    state.signatures.tiles = undefined;
    const text = unit && !hasTelemetry()
      ? (state.telemetryReason ? `Телеметрия недоступна: ${state.telemetryReason}` : "Датчики к этому агрегату не подключены.")
      : telemetry ? "Сервер не прислал ни одного параметра." : "Показания загружаются.";
    dom.tiles.replaceChildren(el("p", {class: "empty", text}));
    dom.labels.replaceChildren();
    dom.telemetryStamp.textContent = "";
    dom.chartTitle.textContent = "График";
    return;
  }
  renderIfChanged("tiles", telemetry.params.map((param) => param.code), () => buildTiles(telemetry.params));
  for (const param of telemetry.params) {
    const tile = dom.tiles.querySelector(`[data-code="${CSS.escape(param.code)}"]`);
    if (!tile) {
      continue;
    }
    tile.className = `tile ${param.level}`;
    tile.setAttribute("aria-pressed", param.code === state.paramCode ? "true" : "false");
    tile.title = [param.name, param.basis].filter(Boolean).join(". ");
    const [name, , note] = tile.children;
    name.textContent = param.name;
    if (param.source === "model" && !name.querySelector(".tile-model")) {
      name.append(el("span", {class: "tile-model", text: "модель"}));
    }
    tile.querySelector(".tile-value").textContent = tileValue(param);
    tile.querySelector(".tile-unit").textContent = param.code === "mode" || param.value === null ? "" : param.unit;
    note.textContent = tileNote(param);
  }
  const labels = [];
  for (const [kind, title] of [["vibration", "по вибрации"], ["temperature", "по температуре"]]) {
    const label = telemetry.labels[kind];
    if (!label) {
      continue;
    }
    const text = label.text;
    const tone = !text ? "" : text.startsWith("Тревога") ? "defect" : text.startsWith("Пред") ? "check"
      : text === "Норма" ? "ok" : "";
    const who = label.source === "model" ? `Диагноз ${title} по уставкам заказчика (модельный час)`
      : `Диагноз заказчика ${title}`;
    labels.push(el("span", {
      class: `chip ${tone}`,
      title: label.source === "model" ? "На этот час записи в базе заказчика нет: диагноз посчитан по его уставкам" : null,
      text: text ? `${who}: ${text}` : `${who}: записи на этот час нет`,
    }));
  }
  dom.labels.replaceChildren(...labels);
  dom.telemetryStamp.textContent = telemetry.cursor !== null ? `на ${showDate(telemetry.cursor)}, обновление каждые 2 с` : "";
  const param = selectedParam();
  dom.chartTitle.textContent = param ? `График: ${param.name}${param.unit ? `, ${param.unit}` : ""}` : "График";
}

/** Выбирает параметр для графика. */
function chooseParam(code) {
  state.paramCode = code;
  dom.forecast.textContent = "";
  renderTelemetry();
  loadChart(state.unitId);
}

/** Выбирает период графика в часах. */
function chooseHours(hours) {
  state.hours = hours;
  for (const button of dom.chartHours.children) {
    button.setAttribute("aria-pressed", Number(button.dataset.hours) === hours ? "true" : "false");
  }
  loadChart(state.unitId);
}

/** Подбирает ровные деления оси значений. */
function axisTicks(low, high, count) {
  const rough = (high - low) / count;
  const power = Math.pow(10, Math.floor(Math.log10(rough)));
  const step = [1, 2, 2.5, 5, 10].find((factor) => factor * power >= rough) * power;
  const ticks = [];
  for (let value = Math.ceil(low / step) * step; value <= high + step * 1e-6; value += step) {
    ticks.push(Math.abs(value) < step * 1e-6 ? 0 : value);
  }
  const digits = Math.max(0, Math.min(4, -Math.floor(Math.log10(step) + 1e-9) + (step / power === 2.5 ? 1 : 0)));
  return {ticks, digits};
}

/** Читает цвет из переменных оформления страницы. */
function themeColor(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

/** Рисует график выбранного параметра: ряд значений, линии уставок, зоны за уставками и подсказку под курсором. */
function drawChart() {
  const canvas = dom.chart;
  const width = canvas.parentElement.clientWidth;
  const height = canvas.parentElement.clientHeight;
  if (!width || !height) {
    return;
  }
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.round(width * ratio);
  canvas.height = Math.round(height * ratio);
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  const family = getComputedStyle(document.body).fontFamily;
  const soft = themeColor("--text-soft");
  ctx.font = `12px ${family}`;
  ctx.textBaseline = "middle";
  const points = state.chart.points;
  const param = selectedParam();
  if (!points.length || !param) {
    ctx.fillStyle = soft;
    ctx.textAlign = "center";
    ctx.font = `14px ${family}`;
    const text = !hasTelemetry() ? "Для этого агрегата графиков нет: датчики не подключены"
      : state.chart.key ? "За выбранный период значений нет" : "График загружается";
    ctx.fillText(text, width / 2, height / 2);
    return;
  }
  const frame = {left: 58, right: width - 14, top: 14, bottom: height - 28};
  const limits = [];
  if (param.direction && param.warn !== null) {
    limits.push({value: param.warn, title: "Предупреждение", color: themeColor("--check"), fill: "rgba(227, 154, 12, 0.10)"});
  }
  if (param.direction && param.alarm !== null) {
    limits.push({value: param.alarm, title: "Тревога", color: themeColor("--defect"), fill: "rgba(217, 59, 48, 0.10)"});
  }
  let low = Math.min(...points.map((point) => point.value), ...limits.map((limit) => limit.value));
  let high = Math.max(...points.map((point) => point.value), ...limits.map((limit) => limit.value));
  if (high - low < 1e-9) {
    low -= 1;
    high += 1;
  }
  const margin = (high - low) * 0.1;
  low -= margin;
  high += margin;
  const end = state.chart.end !== null ? state.chart.end : points[points.length - 1].at;
  const begin = Math.min(end - state.hours * HOUR_MS, points[0].at);
  const toX = (at) => frame.left + (at - begin) / (end - begin) * (frame.right - frame.left);
  const toY = (value) => frame.bottom - (value - low) / (high - low) * (frame.bottom - frame.top);

  for (const limit of limits) {
    const edge = toY(limit.value);
    ctx.fillStyle = limit.fill;
    if (param.direction === "low") {
      ctx.fillRect(frame.left, edge, frame.right - frame.left, frame.bottom - edge);
    } else {
      ctx.fillRect(frame.left, frame.top, frame.right - frame.left, edge - frame.top);
    }
  }

  const axis = axisTicks(low, high, 5);
  ctx.strokeStyle = themeColor("--border");
  ctx.lineWidth = 1;
  ctx.fillStyle = soft;
  ctx.textAlign = "right";
  for (const tick of axis.ticks) {
    const y = Math.round(toY(tick)) + 0.5;
    ctx.beginPath();
    ctx.moveTo(frame.left, y);
    ctx.lineTo(frame.right, y);
    ctx.stroke();
    ctx.fillText(formatNumber(tick, axis.digits), frame.left - 8, y);
  }

  const stepHours = state.hours <= 12 ? 3 : state.hours <= 24 ? 6 : state.hours <= 72 ? 24 : 48;
  ctx.textAlign = "center";
  for (let at = Math.ceil(begin / (stepHours * HOUR_MS)) * stepHours * HOUR_MS; at <= end; at += stepHours * HOUR_MS) {
    const x = toX(at);
    if (x < frame.left + 14 || x > frame.right - 14) {
      continue;
    }
    const date = new Date(at);
    const text = stepHours >= 24 || date.getUTCHours() === 0 ? showDay(at) : `${pad(date.getUTCHours())}:00`;
    ctx.fillText(text, x, frame.bottom + 14);
  }

  ctx.beginPath();
  points.forEach((point, index) => {
    if (index === 0) {
      ctx.moveTo(toX(point.at), toY(point.value));
    } else {
      ctx.lineTo(toX(point.at), toY(point.value));
    }
  });
  ctx.strokeStyle = themeColor("--blue");
  ctx.lineWidth = 2;
  ctx.lineJoin = "round";
  ctx.stroke();

  ctx.font = `500 12px ${family}`;
  ctx.textAlign = "left";
  for (const limit of limits) {
    const y = Math.round(toY(limit.value)) + 0.5;
    ctx.setLineDash([6, 4]);
    ctx.strokeStyle = limit.color;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(frame.left, y);
    ctx.lineTo(frame.right, y);
    ctx.stroke();
    ctx.setLineDash([]);
    const text = `${limit.title} ${withUnit(limit.value, param.unit)}`;
    const size = ctx.measureText(text).width;
    ctx.fillStyle = "rgba(255, 255, 255, 0.9)";
    ctx.fillRect(frame.left + 6, y - 17, size + 8, 15);
    ctx.fillStyle = limit.color === themeColor("--check") ? themeColor("--check-text") : themeColor("--defect-text");
    ctx.fillText(text, frame.left + 10, y - 9);
  }

  const marked = state.chart.hover !== null && points[state.chart.hover] ? points[state.chart.hover] : points[points.length - 1];
  const x = toX(marked.at);
  const y = toY(marked.value);
  if (state.chart.hover !== null) {
    ctx.strokeStyle = soft;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(Math.round(x) + 0.5, frame.top);
    ctx.lineTo(Math.round(x) + 0.5, frame.bottom);
    ctx.stroke();
  }
  ctx.fillStyle = themeColor("--blue");
  ctx.beginPath();
  ctx.arc(x, y, 4.5, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = "#FFFFFF";
  ctx.lineWidth = 2;
  ctx.stroke();
  const caption = `${showDate(marked.at)}  ${withUnit(marked.value, param.unit)}`;
  const captionWidth = ctx.measureText(caption).width + 16;
  const boxX = Math.min(frame.right - captionWidth, Math.max(frame.left, x - captionWidth / 2));
  const boxY = y - 34 < frame.top ? y + 12 : y - 34;
  ctx.fillStyle = themeColor("--blue-deep");
  ctx.fillRect(boxX, boxY, captionWidth, 22);
  ctx.fillStyle = "#FFFFFF";
  ctx.fillText(caption, boxX + 8, boxY + 11);
}

/** Находит ближайшую к указателю точку графика и показывает её значение. */
function hoverChart(event) {
  const points = state.chart.points;
  if (!points.length) {
    return;
  }
  const box = dom.chart.getBoundingClientRect();
  const left = 58;
  const right = box.width - 14;
  const end = state.chart.end !== null ? state.chart.end : points[points.length - 1].at;
  const begin = Math.min(end - state.hours * HOUR_MS, points[0].at);
  const at = begin + (event.clientX - box.left - left) / (right - left) * (end - begin);
  let best = 0;
  points.forEach((point, index) => {
    if (Math.abs(point.at - at) < Math.abs(points[best].at - at)) {
      best = index;
    }
  });
  if (state.chart.hover !== best) {
    state.chart.hover = best;
    drawChart();
  }
}

/** Метка со статусом: цвет и подпись по словарю. */
function statusChip(status, titles) {
  return el("span", {class: `chip ${status === "ok" || status === "check" || status === "defect" ? status : ""}`,
    text: titles[status] || titles.unknown || "Нет данных"});
}

/** Таблица оснований находки: источник, признак, значение, уставка и выполнено ли условие. */
function evidenceTable(evidence) {
  const rows = (Array.isArray(evidence) ? evidence : []).filter((row) => row && typeof row === "object" && row.what);
  if (!rows.length) {
    return null;
  }
  return el("table", {class: "evidence"}, [
    el("thead", {}, el("tr", {}, ["Источник", "Признак", "Значение", "Уставка", "Условие"].map(
      (title) => el("th", {scope: "col", text: title})))),
    el("tbody", {}, rows.map((row) => el("tr", {}, [
      el("td", {text: SOURCES[row.source] || row.source || ""}),
      el("td", {text: String(row.what)}),
      el("td", {text: row.value === null || row.value === undefined ? "нет данных" : String(row.value)}),
      el("td", {text: row.threshold === null || row.threshold === undefined ? "-" : String(row.threshold)}),
      el("td", {class: row.met ? "met" : "unmet", text: row.met ? "выполнено" : "не выполнено"}),
    ]))),
  ]);
}

/**
 * Карточка находки или замечания: статус, правило, узел, диагноз, рекомендация, основания и недостающие проверки.
 * expanded - основания раскрыты сразу; actions - кнопки под карточкой.
 */
function findingCard(finding, options = {}) {
  const facts = [];
  if (options.equipmentName) {
    facts.push(options.equipmentName);
  }
  facts.push(finding.node_name || nodeName(finding.node_id || finding.node_code));
  if (SEVERITY[finding.severity]) {
    facts.push(`важность: ${SEVERITY[finding.severity]}`);
  }
  const confidence = toNumber(finding.confidence);
  if (confidence !== null && confidence > 0) {
    facts.push(`достоверность ${formatNumber(confidence * 100, 0)} %`);
  }
  if (finding.created_at) {
    facts.push(`осмотр № ${finding.inspection_id} от ${showStamp(finding.created_at)}`);
  }
  if (finding.automatic) {
    facts.push("записано автоматически при завершении осмотра");
  }
  const table = evidenceTable(finding.evidence);
  const missing = Array.isArray(finding.missing) ? finding.missing.filter(Boolean) : [];
  return el("article", {class: "finding"}, [
    el("div", {class: "finding-head"}, [
      statusChip(finding.status, FINDING_STATUS),
      finding.rule_id ? el("span", {class: "chip plain info", text: finding.rule_id}) : null,
      el("span", {class: "finding-title", text: finding.title || "Замечание без названия"}),
    ]),
    el("p", {class: "finding-meta", text: facts.join(", ")}),
    finding.diagnosis ? el("p", {text: finding.diagnosis}) : null,
    finding.recommendation ? el("p", {}, [
      el("span", {class: "finding-label", text: "Рекомендация: "}), finding.recommendation]) : null,
    missing.length ? el("div", {}, [
      el("span", {class: "finding-label", text: "Что ещё проверить:"}),
      el("ul", {class: "missing"}, missing.map((item) => el("li", {text: String(item)}))),
    ]) : null,
    finding.comment ? el("p", {class: "comment", text: finding.comment}) : null,
    table ? el("details", {open: Boolean(options.expanded)}, [
      el("summary", {text: `Основания: ${table.querySelectorAll("tbody tr").length}`}), table]) : null,
    options.actions && options.actions.length ? el("div", {class: "finding-actions"}, options.actions) : null,
  ]);
}

/** Рисует общий вывод и находки текущего диагноза с основаниями. */
function renderDiagnosis() {
  const diagnosis = state.diagnosis;
  renderIfChanged("diagnosis", {diagnosis, card: state.card ? state.card.id : null}, () => {
    if (!diagnosis) {
      dom.verdict.className = "verdict";
      dom.verdict.replaceChildren(el("p", {class: "verdict-title", text: "Диагноз загружается"}));
      dom.diagnosis.replaceChildren();
      return;
    }
    dom.verdict.className = `verdict ${diagnosis.status}`;
    dom.verdict.replaceChildren(
      el("p", {class: "verdict-title", text: STATUS_FULL[diagnosis.status]}),
      STATUS_NOTE[diagnosis.status] ? el("p", {class: "verdict-note", text: STATUS_NOTE[diagnosis.status]}) : "");
    if (!diagnosis.findings.length) {
      dom.diagnosis.replaceChildren(el("p", {class: "empty", text: "Правила диагностики сейчас не сработали."}));
      return;
    }
    dom.diagnosis.replaceChildren(...diagnosis.findings.map((finding) => findingCard(finding, {expanded: true})));
  });
}

/** Рисует порядок осмотра узлов с причиной приоритета. */
function renderRoute(route) {
  if (!route.length) {
    dom.route.replaceChildren(el("li", {class: "empty", text: "Порядок осмотра не получен или узлов нет."}));
    return;
  }
  dom.route.replaceChildren(...route.map((step) => el("li", {}, [
    el("span", {class: "route-name", text: step.name || nodeName(step.code || step.node_id)}),
    step.reason ? el("span", {class: "route-reason", text: step.reason}) : null,
  ])));
}

/** Рисует список оборудования со статусом, режимом и числом незакрытых замечаний. */
function renderUnits() {
  const view = state.units.map((unit) => ({unit, status: state.unitStatus[unit.id] || null, chosen: unit.id === state.unitId}));
  renderIfChanged("units", view, () => {
    if (!view.length) {
      dom.units.replaceChildren(el("p", {class: "empty", text: "Оборудование не загружено."}));
      return;
    }
    dom.units.replaceChildren(...view.map(({unit, status, chosen}) => {
      const opened = toNumber(unit.open_findings) || 0;
      const chip = status === "failed" ? el("span", {class: "chip", text: "Статус не получен"})
        : status ? statusChip(status, STATUS_SHORT) : el("span", {class: "chip", text: "Статус загружается"});
      return el("button", {
        class: "unit", type: "button", "aria-pressed": chosen ? "true" : "false",
        on: {click: () => selectUnit(unit.id)},
      }, [
        el("span", {class: "unit-name", text: unit.name || unit.id}),
        el("span", {class: "unit-meta", text: [unit.model, unit.location].filter(Boolean).join(", ")}),
        el("span", {class: "unit-chips"}, [
          chip,
          el("span", {class: "chip plain", text: MODES[unit.mode] || "Режим неизвестен"}),
          el("span", {class: `chip plain ${opened ? "check" : ""}`, text: `Незакрытых замечаний: ${opened}`}),
        ]),
        el("span", {class: "unit-meta", text: unit.last_inspection_at
          ? `Последний осмотр: ${showStamp(unit.last_inspection_at)}` : "Осмотров ещё не было"}),
        el("span", {class: "unit-meta", text: unit.telemetry ? "Датчики подключены" : "Без датчиков"}),
      ]);
    }));
  });
}

/** Скачивает отчёт об осмотре: файл запрашивается с токеном и сохраняется браузером. */
async function downloadReport(inspectionId, extension, button) {
  button.disabled = true;
  try {
    const blob = await request("GET", `/inspections/${inspectionId}/report.${extension}`, {blob: true});
    const url = URL.createObjectURL(blob);
    const link = el("a", {href: url, download: `kst-vizor-osmotr-${inspectionId}.${extension}`});
    document.body.append(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 30000);
  } catch (error) {
    notify(`Отчёт по осмотру № ${inspectionId} не получен: ${error instanceof ApiError ? error.message : "ошибка страницы"}`);
  } finally {
    button.disabled = false;
  }
}

/** Запись истории об осмотре: кто, когда, итог, находки и кнопки отчётов. */
function inspectionEntry(entry) {
  const summary = entry.summary && typeof entry.summary === "object" ? entry.summary : {};
  const counts = summary.by_status && typeof summary.by_status === "object" ? summary.by_status : null;
  const facts = [];
  if (entry.user && entry.user.name) {
    facts.push(entry.user.role_title ? `${entry.user.name} (${entry.user.role_title})` : entry.user.name);
  }
  if (counts) {
    facts.push(`без замечаний ${counts.ok || 0}, проверка ${counts.check || 0}, дефект ${counts.defect || 0}`);
  }
  if (showDuration(summary.duration_s)) {
    facts.push(`длительность ${showDuration(summary.duration_s)}`);
  }
  const findings = (Array.isArray(entry.findings) ? entry.findings : []).filter((finding) => finding.status !== "ok");
  const worst = findings.some((finding) => finding.status === "defect") ? "defect" : findings.length ? "check" : "ok";
  return el("article", {class: "entry"}, [
    el("div", {class: "entry-head"}, [
      el("span", {class: "entry-title", text: `Осмотр № ${entry.id}`}),
      el("span", {class: "muted", text: showStamp(entry.started_at || entry.at)}),
      el("span", {class: "chip plain info", text: INSPECTION_STATUS[entry.status] || entry.status || ""}),
      entry.status === "finished" ? statusChip(worst, FINDING_STATUS) : null,
    ]),
    el("p", {class: "finding-meta", text: facts.join("; ")}),
    findings.length ? el("ul", {class: "entry-list"}, findings.map((finding) => el("li", {
      text: `${finding.node_name || WHOLE_UNIT}: ${finding.title || "замечание"}`}))) : null,
    el("div", {class: "finding-actions"}, [
      el("button", {class: "button ghost small", type: "button", text: "Отчёт PDF",
        on: {click: (event) => downloadReport(entry.id, "pdf", event.currentTarget)}}),
      el("button", {class: "button ghost small", type: "button", text: "Отчёт Excel",
        on: {click: (event) => downloadReport(entry.id, "xlsx", event.currentTarget)}}),
    ]),
  ]);
}

/** Запись истории о работе на узле: проверка, обслуживание или замена. */
function workEntry(entry) {
  const facts = [];
  if (entry.user && entry.user.name) {
    facts.push(entry.user.name);
  }
  if (toNumber(entry.hours_at) !== null) {
    facts.push(`при наработке ${withUnit(toNumber(entry.hours_at), "ч", 0)}`);
  }
  return el("article", {class: "entry"}, [
    el("div", {class: "entry-head"}, [
      el("span", {class: "entry-title", text: WORK_KINDS[entry.kind] || "Работа на узле"}),
      el("span", {class: "muted", text: showStamp(entry.at)}),
      el("span", {class: "chip plain", text: entry.node_name || nodeName(entry.node_code)}),
    ]),
    entry.comment ? el("p", {text: entry.comment}) : null,
    facts.length ? el("p", {class: "finding-meta", text: facts.join(", ")}) : null,
  ]);
}

/** Рисует историю осмотров и работ, сначала новые; null означает, что данные ещё загружаются. */
function renderHistory(entries) {
  if (entries === null) {
    dom.history.replaceChildren(el("p", {class: "empty", text: "История загружается."}));
    return;
  }
  if (!entries.length) {
    dom.history.replaceChildren(el("p", {class: "empty", text: "Осмотров и работ по этому агрегату ещё не было."}));
    return;
  }
  dom.history.replaceChildren(...entries.map((entry) => entry.type === "maintenance" ? workEntry(entry) : inspectionEntry(entry)));
}

/** Показывает снимок, приложенный к замечанию: файл запрашивается с токеном. */
async function showPhoto(findingId, button) {
  button.disabled = true;
  try {
    const blob = await request("GET", `/inspections/findings/${findingId}/photo`, {blob: true});
    if (state.photoUrl) {
      URL.revokeObjectURL(state.photoUrl);
    }
    state.photoUrl = URL.createObjectURL(blob);
    dom.photoImage.src = state.photoUrl;
    dom.photoDialog.showModal();
  } catch (error) {
    notify(`Снимок не получен: ${error instanceof ApiError ? error.message : "ошибка страницы"}`);
  } finally {
    button.disabled = false;
  }
}

/** Переводит замечание в следующее состояние и обновляет доску и список оборудования. */
async function advanceFinding(finding, button) {
  button.disabled = true;
  try {
    await request("POST", `/inspections/findings/${finding.id}/state`, {json: {state: NEXT_STATE[finding.state]}});
  } catch (error) {
    notify(`Состояние замечания не изменено: ${error instanceof ApiError ? error.message : "ошибка страницы"}`);
  }
  await loadFindings();
  await loadUnits();
  if (button.isConnected) {
    button.disabled = false;
  }
}

/** Рисует доску замечаний в три колонки: открыто, в работе, устранено. */
function renderBoard(findings) {
  const allowed = canConfirm();
  for (const column of ["open", "in_work", "resolved"]) {
    const own = findings.filter((finding) => finding.state === column);
    document.getElementById(`count-${column}`).textContent = String(own.length);
    const cards = own.map((finding) => {
      const actions = [];
      if (finding.has_photo) {
        actions.push(el("button", {class: "button ghost small", type: "button", text: "Показать снимок",
          on: {click: (event) => showPhoto(finding.id, event.currentTarget)}}));
      }
      if (allowed && NEXT_STATE[finding.state]) {
        actions.push(el("button", {class: "button primary small", type: "button", text: NEXT_STATE_ACTION[finding.state],
          on: {click: (event) => advanceFinding(finding, event.currentTarget)}}));
      }
      return findingCard(finding, {equipmentName: state.boardScope === "all" ? finding.equipment_name : "", actions});
    });
    document.getElementById(`board-${column}`).replaceChildren(
      ...(cards.length ? cards : [el("p", {class: "empty", text: "Замечаний нет."})]));
  }
}

/** Выбирает, чьи замечания показывать на доске. */
function chooseScope(scope) {
  state.boardScope = scope;
  for (const button of dom.boardScope.children) {
    button.setAttribute("aria-pressed", button.dataset.scope === scope ? "true" : "false");
  }
  loadFindings();
}

/** Отправляет вопрос помощнику и показывает ответ со ссылками для мобильного приложения. */
async function askAssistant(event) {
  event.preventDefault();
  const question = dom.askInput.value.trim();
  if (!can(PERMISSION.assistant)) {
    setSectionError("assistant", "Помощник недоступен: у вашей роли нет права «Вопросы помощнику».");
    return;
  }
  if (!question) {
    setSectionError("assistant", "Введите вопрос.");
    return;
  }
  dom.askSubmit.disabled = true;
  const reply = await load("assistant", "Помощник не ответил",
    () => request("POST", "/assistant/ask", {json: {question, equipment_id: state.unitId}}));
  dom.askSubmit.disabled = false;
  if (reply === undefined) {
    return;
  }
  const links = Array.isArray(reply.links) ? reply.links : [];
  dom.answer.hidden = false;
  dom.answer.replaceChildren(
    el("p", {class: "answer-text", text: reply.answer || "Помощник прислал пустой ответ."}),
    links.length ? el("div", {class: "answer-links"}, links.map((link) => el("span", {class: "answer-link"}, [
      el("span", {text: link.title || ""}), el("code", {text: link.deeplink || ""})]))) : "",
    el("p", {class: "muted", text: reply.mode === "llm"
      ? "Текст сформулирован локальной моделью по фактам из базы; ссылки открываются в мобильном приложении."
      : "Ответ собран поиском по базе; ссылки открываются в мобильном приложении."}));
}

/** Показывает рабочий экран после входа и запускает загрузку и периодическое обновление. */
function startApp() {
  dom.login.hidden = true;
  dom.app.hidden = false;
  const user = state.session.user || {};
  dom.userName.textContent = [user.name, user.role_title].filter(Boolean).join(", ");
  dom.linkState.className = "link-state";
  dom.linkState.textContent = "Подключение к серверу";
  state.unitId = null;
  state.units = [];
  state.unitStatus = {};
  state.signatures = {};
  dom.answer.hidden = true;
  dom.askInput.value = "";
  chooseHours(state.hours);
  for (const button of dom.boardScope.children) {
    button.setAttribute("aria-pressed", button.dataset.scope === state.boardScope ? "true" : "false");
  }
  renderUnits();
  startTimers();
  slowTick();
}

/**
 * Решает, что показать вошедшему: смену временного пароля, отказ роли без права «Просмотр оборудования»
 * или рабочий экран. password - только что введённый пароль, чтобы не просить его повторно.
 */
async function enterApp(password) {
  const user = state.session.user || {};
  if (user.must_change_password) {
    askNewPassword(password || "");
    return;
  }
  if (!can(PERMISSION.panel)) {
    await signOut(`Для роли «${user.role_title || user.role || "без названия"}» пульт демонстрации недоступен: `
      + "нужно право «Просмотр оборудования».");
    return;
  }
  startApp();
}

/** Показывает форму смены временного пароля; известный временный пароль подставляется сам. */
function askNewPassword(current) {
  dom.app.hidden = true;
  dom.login.hidden = false;
  dom.loginForm.hidden = true;
  dom.passwordForm.hidden = false;
  dom.passwordCurrent.value = current;
  dom.passwordNew.value = "";
  dom.passwordRepeat.value = "";
  dom.passwordError.hidden = true;
  (current ? dom.passwordNew : dom.passwordCurrent).focus();
}

/** Показывает ошибку под формой смены пароля. */
function passwordFailed(message) {
  dom.passwordError.hidden = false;
  dom.passwordError.textContent = message;
}

/** Меняет временный пароль на постоянный и после успеха открывает пульт. */
async function changePassword(event) {
  event.preventDefault();
  const current = dom.passwordCurrent.value;
  const fresh = dom.passwordNew.value;
  if (!current || !fresh) {
    passwordFailed("Заполните все поля.");
    return;
  }
  if (fresh !== dom.passwordRepeat.value) {
    passwordFailed("Новый пароль и повтор не совпадают.");
    return;
  }
  dom.passwordSubmit.disabled = true;
  dom.passwordError.hidden = true;
  try {
    const reply = await request("POST", "/auth/password", {json: {current_password: current, new_password: fresh}});
    state.session.user = reply.user;
    saveSession();
    dom.passwordForm.hidden = true;
    dom.loginForm.hidden = false;
    await enterApp("");
  } catch (error) {
    if (state.session) {
      passwordFailed(error instanceof ApiError ? `Пароль не изменён: ${error.message}` : "Пароль не изменён: ошибка страницы");
    }
  } finally {
    dom.passwordSubmit.disabled = false;
  }
}

/** Выполняет вход по почте и паролю; ошибка показывается под формой. */
async function signIn(email, password) {
  dom.loginSubmit.disabled = true;
  dom.loginError.hidden = true;
  try {
    const reply = await request("POST", "/auth/login", {json: {email, password, device: "Пульт демонстрации"}, open: true});
    storeSession(reply);
    await enterApp(password);
  } catch (error) {
    dom.loginError.hidden = false;
    dom.loginError.textContent = error instanceof ApiError ? `Вход не выполнен: ${error.message}` : "Вход не выполнен: ошибка страницы";
  } finally {
    dom.loginSubmit.disabled = false;
  }
}

/** Выходит из системы: сервер отзывает сессию, страница возвращается ко входу с пояснением message. */
async function signOut(message = "") {
  try {
    await request("POST", "/auth/logout");
  } catch (error) {
    notify("Сервер не подтвердил выход - сессия стёрта только на этой странице");
  }
  endSession(message);
}

/** Обрабатывает клавиши на шкале времени: стрелки сдвигают на час, PageUp и PageDown - на сутки. */
function stripKey(event) {
  const shifts = {ArrowLeft: -1, ArrowRight: 1, ArrowDown: -1, ArrowUp: 1, PageDown: -24, PageUp: 24};
  const telemetry = state.telemetry;
  if (!canControl() || !telemetry || telemetry.cursor === null) {
    return;
  }
  if (shifts[event.key]) {
    event.preventDefault();
    stepCursor(shifts[event.key]);
  } else if (event.key === "Home" || event.key === "End") {
    event.preventDefault();
    setPlaying(false);
    moveCursor(event.key === "Home" ? telemetry.first : telemetry.last);
  }
}

/** Переносит время стенда в точку шкалы, по которой щёлкнули. */
function stripClick(event) {
  const telemetry = state.telemetry;
  if (!canControl() || !telemetry || telemetry.first === null || telemetry.last === null) {
    return;
  }
  const box = dom.strip.getBoundingClientRect();
  const share = Math.min(1, Math.max(0, (event.clientX - box.left) / box.width));
  setPlaying(false);
  moveCursor(telemetry.first + share * (telemetry.last - telemetry.first));
}

/** Находит элементы страницы и навешивает обработчики. */
function bind() {
  const ids = {
    alerts: "alerts", login: "login", loginForm: "login-form", loginEmail: "login-email", loginPassword: "login-password",
    loginError: "login-error", loginSubmit: "login-submit", app: "app", linkState: "link-state", userName: "user-name",
    logout: "logout", consoleUnit: "console-unit", cursorTime: "cursor-time", cursorOrigin: "cursor-origin",
    consoleNote: "console-note", consoleBody: "console-body", scenarios: "scenarios", strip: "strip",
    stripBands: "strip-bands", stripNeedle: "strip-needle", stripTicks: "strip-ticks", play: "play", units: "units",
    telemetryStamp: "telemetry-stamp", labels: "labels", tiles: "tiles", chartTitle: "chart-title",
    chartHours: "chart-hours", chart: "chart", forecast: "forecast", verdict: "verdict", diagnosis: "diagnosis",
    route: "route", history: "history", boardScope: "board-scope", askForm: "ask-form", askInput: "ask-input",
    askSubmit: "ask-submit", answer: "answer", photoDialog: "photo-dialog", photoImage: "photo-image",
    passwordForm: "password-form", passwordCurrent: "password-current", passwordNew: "password-new",
    passwordRepeat: "password-repeat", passwordError: "password-error", passwordSubmit: "password-submit",
  };
  for (const [name, id] of Object.entries(ids)) {
    dom[name] = document.getElementById(id);
  }
  dom.steps = Array.from(document.querySelectorAll(".step[data-step]"));

  dom.loginForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const email = dom.loginEmail.value.trim();
    if (!email || !dom.loginPassword.value) {
      dom.loginError.hidden = false;
      dom.loginError.textContent = "Введите почту и пароль.";
      return;
    }
    signIn(email, dom.loginPassword.value);
  });
  for (const button of document.querySelectorAll("[data-demo]")) {
    button.addEventListener("click", () => {
      dom.loginEmail.value = button.dataset.demo;
      dom.loginPassword.value = DEMO_PASSWORD;
      signIn(button.dataset.demo, DEMO_PASSWORD);
    });
  }
  dom.logout.addEventListener("click", () => signOut(""));
  dom.passwordForm.addEventListener("submit", changePassword);
  for (const button of dom.steps) {
    button.addEventListener("click", () => stepCursor(Number(button.dataset.step)));
  }
  dom.play.addEventListener("click", () => setPlaying(!state.playing));
  dom.strip.addEventListener("click", stripClick);
  dom.strip.addEventListener("keydown", stripKey);
  for (const button of dom.chartHours.children) {
    button.addEventListener("click", () => chooseHours(Number(button.dataset.hours)));
  }
  for (const button of dom.boardScope.children) {
    button.addEventListener("click", () => chooseScope(button.dataset.scope));
  }
  dom.chart.addEventListener("mousemove", hoverChart);
  dom.chart.addEventListener("mouseleave", () => {
    state.chart.hover = null;
    drawChart();
  });
  dom.askForm.addEventListener("submit", askAssistant);
  dom.photoDialog.addEventListener("close", () => {
    if (state.photoUrl) {
      URL.revokeObjectURL(state.photoUrl);
      state.photoUrl = null;
    }
    dom.photoImage.removeAttribute("src");
  });
  if (window.ResizeObserver) {
    new ResizeObserver(() => drawChart()).observe(dom.chart.parentElement);
  } else {
    window.addEventListener("resize", drawChart);
  }
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(() => drawChart());
  }
}

/** Запускает страницу: восстанавливает сессию вкладки или показывает вход. */
async function main() {
  bind();
  state.session = readStoredSession();
  if (!state.session) {
    endSession("");
    return;
  }
  try {
    state.session.user = await request("GET", "/auth/me");
    saveSession();
    await enterApp("");
  } catch (error) {
    if (state.session) {
      endSession(error instanceof ApiError && error.status === 0
        ? "Нет связи с сервером - проверьте, что он запущен, и войдите снова" : "Сессия завершена - войдите снова");
    }
  }
}

document.addEventListener("DOMContentLoaded", main);
