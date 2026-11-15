"use client";

import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from "react";
import { createPortal } from "react-dom";

/** План действия, которое помощник предлагает выполнить после подтверждения. */
interface Plan {
  id: string;
  action: string;
  title: string;
  details: [string, string][];
  danger: boolean;
  [extra: string]: unknown;
}

/** Итог выполненного действия: строки и разовый секрет (например, временный пароль). */
interface Result {
  title: string;
  rows: [string, string][];
  secret: string | null;
}

/** Ответ сервера на сообщение помощнику. */
interface Reply {
  reply: string;
  plan: Plan | null;
  done: boolean;
  result: Result | null;
  links: { label: string; route: string }[];
  suggestions: string[];
}

/** Сообщение в ленте: вопрос сотрудника или ответ помощника. */
interface Message {
  id: number;
  who: "me" | "bot";
  text: string;
  ask?: string;
  plan?: Plan | null;
  state?: "wait" | "done" | "cancel";
  result?: Result | null;
  links?: Reply["links"];
  suggestions?: string[];
  error?: boolean;
}

const ENDPOINT = "/webadmin/assistant";

/** Значок из набора оформления панели. */
function Icon({ name, size = 18 }: { name: string; size?: number }) {
  const icons = window.KV?.ICONS ?? {};
  return (
    <svg
      className="ic"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      dangerouslySetInnerHTML={{ __html: icons[name] ?? icons.info ?? "" }}
    />
  );
}

/** Подсказки до первого вопроса: по разделам, которые доступны сотруднику. */
function startChips(wa: WebAdmin): string[] {
  const can = (p: string) => !!wa.user?.permissions.includes(p);
  const out: string[] = [];
  if (can("users.manage")) out.push("Создай пользователя инженера", "Кто сейчас заблокирован?");
  if (can("security.log")) out.push("Неудачные входы за сутки");
  if (can("system.manage")) out.push("Состояние сервера", "Сделай резервную копию");
  if (!out.length) out.push("Что произошло за смену?");
  return out.slice(0, 4);
}

/** Адрес раздела из ответа помощника: ключ страницы панели и параметры. */
function parseRoute(route: string): { key: string; params: Record<string, string> } {
  let r = route.trim();
  try {
    const u = new URL(r, location.href);
    if (u.origin === location.origin) r = u.pathname.replace(/^\/web\/?/, "") + u.search + u.hash;
  } catch {
    r = route.trim();
  }
  r = r.replace(/^#?\/?/, "").replace(/^#\/?/, "");
  const [key, query = ""] = r.split("?");
  const params: Record<string, string> = {};
  new URLSearchParams(query).forEach((v, k) => {
    params[k] = v;
  });
  return { key, params };
}

/** Чат с помощником администратора: плавающая кнопка и боковая панель поверх страниц веб-панели. */
export default function Assistant() {
  const wa = window.WA as WebAdmin;
  const [visible, setVisible] = useState(false);
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [items, setItems] = useState<Message[]>([]);
  const [copied, setCopied] = useState<number | null>(null);
  const seq = useRef(1);
  const host = useRef<HTMLDivElement | null>(null);
  const sheet = useRef<HTMLElement | null>(null);
  const scrim = useRef<HTMLDivElement | null>(null);
  const feed = useRef<HTMLDivElement | null>(null);
  const input = useRef<HTMLTextAreaElement | null>(null);
  const userId = useRef<string | number | null>(null);

  if (!host.current && typeof document !== "undefined") {
    host.current = document.createElement("div");
    host.current.className = "wai-host";
  }

  /** Сверяет видимость с состоянием панели и возвращает узел помощника в #app после смены оболочки. */
  const sync = useCallback(() => {
    const cur = wa.current();
    const page = cur ? wa.pages[cur.key] : null;
    const show = !!wa.user && wa.hasWeb() && !!page && !page.full;
    const who = wa.user ? wa.user.id : null;
    if (who !== userId.current) {
      userId.current = who;
      setItems([]);
      setOpen(false);
    }
    setVisible(show);
    if (!show) setOpen(false);
    const h = host.current;
    if (h && wa.root && h.parentNode !== wa.root) wa.root.appendChild(h);
  }, [wa]);

  useEffect(() => {
    const anyWa = wa as WebAdmin & { __aiWrapped?: boolean };
    if (!anyWa.__aiWrapped) {
      const go = wa.go;
      wa.go = function (key, params) {
        go.call(wa, key, params);
        window.dispatchEvent(new Event("kv:route"));
      };
      anyWa.__aiWrapped = true;
    }
    sync();
    const t = window.setInterval(sync, 1000);
    window.addEventListener("kv:route", sync);
    return () => {
      window.clearInterval(t);
      window.removeEventListener("kv:route", sync);
    };
  }, [wa, sync]);

  const still = () => !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

  useEffect(() => {
    if (!open) return;
    if (!still()) {
      sheet.current?.animate([{ transform: "translateX(104%)" }, { transform: "none" }], { duration: 320, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" });
      scrim.current?.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200 });
    }
    const f = window.setTimeout(() => input.current?.focus(), 60);
    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        close();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => {
      window.clearTimeout(f);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  useEffect(() => {
    const el = feed.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [items, busy]);

  /** Закрывает панель с обратной анимацией. */
  function close() {
    const box = sheet.current;
    if (!box || still() || !box.animate) {
      setOpen(false);
      return;
    }
    const a = box.animate([{ transform: "none" }, { transform: "translateX(104%)" }], { duration: 180, easing: "cubic-bezier(0.2, 0, 0, 1)", fill: "both" });
    scrim.current?.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 180, fill: "both" });
    a.onfinish = () => setOpen(false);
  }

  /** Отправляет сообщение; при подтверждении повторяет исходный текст с планом. */
  async function send(ask: string, confirm = false, plan: Plan | null = null) {
    const q = ask.trim();
    if (!q || busy) return;
    if (!confirm) {
      setItems((l) => [...l, { id: seq.current++, who: "me", text: q }]);
      setText("");
    }
    setBusy(true);
    try {
      const r = await wa.post<Reply>(ENDPOINT, { text: q, confirm, plan });
      setItems((l) => [
        ...l,
        {
          id: seq.current++,
          who: "bot",
          text: r?.reply ?? "",
          ask: q,
          plan: r?.plan && !r.done ? r.plan : null,
          state: r?.plan && !r.done ? "wait" : undefined,
          result: r?.result ?? null,
          links: r?.links ?? [],
          suggestions: r?.suggestions ?? [],
        },
      ]);
    } catch (e) {
      const err = e as { status?: number; detail?: string };
      const text = err?.status === 404 ? "Помощник ещё не подключён на сервере." : err?.detail || "Не удалось получить ответ.";
      setItems((l) => [...l, { id: seq.current++, who: "bot", text, error: true }]);
    } finally {
      setBusy(false);
    }
  }

  /** Решение по плану: выполнить (повторный запрос с подтверждением) или отменить. */
  function decide(m: Message, run: boolean) {
    setItems((l) => l.map((x) => (x.id === m.id ? { ...x, state: run ? "done" : "cancel" } : x)));
    if (run && m.plan && m.ask) void send(m.ask, true, m.plan);
    else setItems((l) => [...l, { id: seq.current++, who: "bot", text: "Отменено. Ничего не изменено." }]);
  }

  /** Переход в раздел панели по ссылке из ответа. */
  function follow(route: string) {
    const { key, params } = parseRoute(route);
    if (wa.pages[key]) {
      wa.go(key, params);
      if (window.innerWidth < 1024) close();
    } else if (route.startsWith("/")) {
      location.href = route;
    }
  }

  async function copySecret(m: Message) {
    if (!m.result?.secret) return;
    const ok = await wa.copy(m.result.secret);
    if (ok) {
      setCopied(m.id);
      window.setTimeout(() => setCopied(null), 2000);
    }
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      void send(text);
    }
  }

  if (!visible || !host.current) return null;
  const last = items[items.length - 1];
  const chips = !items.length ? startChips(wa) : last?.who === "bot" && !busy && last.state !== "wait" ? last.suggestions ?? [] : [];

  return createPortal(
    <>
      {!open ? (
        <button className="wai-fab" type="button" aria-label="Помощник администратора" title="Помощник" onClick={() => setOpen(true)}>
          <Icon name="sparkle" size={22} />
        </button>
      ) : null}
      {open ? (
        <div className="ovl wovl is-drawer wai-ovl">
          <div className="ovl-scrim wscrim" ref={scrim} onClick={close} />
          <aside className="wdrawer wai-sheet" role="dialog" aria-label="Помощник" ref={sheet}>
            <div className="wdrawer-h">
              <span className="wai-badge">
                <Icon name="sparkle" size={20} />
              </span>
              <div className="wgrow">
                <h2>Помощник</h2>
                <p>Выполняет действия только после вашего подтверждения</p>
              </div>
              {items.length ? (
                <button className="wbtn ghost icon" type="button" aria-label="Новый разговор" title="Новый разговор" onClick={() => setItems([])}>
                  <Icon name="refresh" />
                </button>
              ) : null}
              <button className="wbtn ghost icon" type="button" aria-label="Закрыть" onClick={close}>
                <Icon name="close" />
              </button>
            </div>
            <div className="wdrawer-b wai-feed" ref={feed} aria-live="polite">
              {!items.length ? (
                <div className="wai-msg bot">
                  <div className="wai-bubble">
                    Здравствуйте, {wa.user?.name?.split(" ")[0] ?? "коллега"}. Опишите задачу своими словами - я подготовлю действие, покажу, что изменится, и выполню его только после
                    подтверждения.
                  </div>
                </div>
              ) : null}
              {items.map((m) => (
                <div key={m.id} className={"wai-msg " + m.who + (m.error ? " is-error" : "")}>
                  {m.text ? <div className="wai-bubble">{m.text}</div> : null}
                  {m.plan ? (
                    <div className={"wai-card" + (m.plan.danger ? " danger" : "") + (m.state !== "wait" ? " is-closed" : "")}>
                      <div className="wai-card-h">
                        <Icon name={m.plan.danger ? "alert" : "check"} />
                        <b>{m.plan.title}</b>
                      </div>
                      {m.plan.details?.length ? (
                        <dl className="wai-rows">
                          {m.plan.details.map(([k, v], i) => (
                            <div key={i}>
                              <dt>{k}</dt>
                              <dd>{v}</dd>
                            </div>
                          ))}
                        </dl>
                      ) : null}
                      {m.state === "wait" ? (
                        <div className="wai-card-f">
                          <span className="wai-note">Ещё ничего не выполнено</span>
                          <button className="wbtn secondary sm" type="button" disabled={busy} onClick={() => decide(m, false)}>
                            <span>Отмена</span>
                          </button>
                          <button className={"wbtn sm " + (m.plan.danger ? "danger" : "primary")} type="button" disabled={busy} onClick={() => decide(m, true)}>
                            <span>Выполнить</span>
                          </button>
                        </div>
                      ) : (
                        <div className="wai-card-f">
                          <span className="wai-note">{m.state === "done" ? "Подтверждено" : "Отменено"}</span>
                        </div>
                      )}
                    </div>
                  ) : null}
                  {m.result ? (
                    <div className="wai-card ok">
                      <div className="wai-card-h">
                        <Icon name="check" />
                        <b>{m.result.title}</b>
                      </div>
                      {m.result.rows?.length ? (
                        <dl className="wai-rows">
                          {m.result.rows.map(([k, v], i) => (
                            <div key={i}>
                              <dt>{k}</dt>
                              <dd>{v}</dd>
                            </div>
                          ))}
                        </dl>
                      ) : null}
                      {m.result.secret ? (
                        <div className="wai-secret">
                          <code>{m.result.secret}</code>
                          <button className="wbtn secondary sm" type="button" onClick={() => copySecret(m)}>
                            <Icon name={copied === m.id ? "check" : "copy"} />
                            <span>{copied === m.id ? "Скопировано" : "Копировать"}</span>
                          </button>
                          <span className="wai-note">Показывается один раз - передайте сотруднику лично</span>
                        </div>
                      ) : null}
                    </div>
                  ) : null}
                  {m.links?.length ? (
                    <div className="wai-links">
                      {m.links.map((l, i) => (
                        <button key={i} className="wlink" type="button" onClick={() => follow(l.route)}>
                          {l.label}
                          <Icon name="arrowRight" size={14} />
                        </button>
                      ))}
                    </div>
                  ) : null}
                </div>
              ))}
              {busy ? (
                <div className="wai-msg bot">
                  <div className="wai-bubble wai-typing" aria-label="Помощник отвечает">
                    <i />
                    <i />
                    <i />
                  </div>
                </div>
              ) : null}
            </div>
            <div className="wdrawer-f wai-foot">
              {chips.length ? (
                <div className="wai-chips">
                  {chips.map((c) => (
                    <button key={c} className="wai-chip" type="button" disabled={busy} onClick={() => send(c)}>
                      {c}
                    </button>
                  ))}
                </div>
              ) : null}
              <div className="wai-compose">
                <span className="winput area wai-input">
                  <textarea
                    ref={input}
                    rows={1}
                    value={text}
                    maxLength={500}
                    placeholder="Например: заблокируй пользователя operator@kst.demo"
                    aria-label="Сообщение помощнику"
                    onChange={(e) => setText(e.target.value)}
                    onKeyDown={onKeyDown}
                  />
                </span>
                <button className={"wbtn primary icon" + (busy ? " is-loading" : "")} type="button" aria-label="Отправить" disabled={busy || !text.trim()} onClick={() => send(text)}>
                  <Icon name="send" />
                </button>
              </div>
            </div>
          </aside>
        </div>
      ) : null}
    </>,
    host.current,
  );
}
