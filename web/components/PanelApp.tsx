"use client";

import { memo, useEffect } from "react";

let loading: Promise<unknown> | null = null;

/**
 * Разметка пульта демонстрации: вход, сценарии и время, оборудование, показания, диагноз, история,
 * замечания и вопрос помощнику. Логика пульта заполняет эти узлы сама, поэтому React рисует их один раз.
 */
const Markup = memo(function Markup() {
  return (
    <>
      <div id="alerts" className="alerts" role="alert" aria-live="assertive"></div>

        <main id="login" className="login" hidden>
          <form id="login-form" className="login-card" noValidate>
            <p className="wordmark">КСТ Визор</p>
            <h1>Пульт демонстрации</h1>
            <p className="muted">Вход по рабочей почте и паролю. Сценариями и временем управляют мастер и администратор системы.</p>
            <label className="field">
              <span>Почта</span>
              <input id="login-email" type="email" name="email" autoComplete="username" required />
            </label>
            <label className="field">
              <span>Пароль</span>
              <input id="login-password" type="password" name="password" autoComplete="current-password" required />
            </label>
            <p id="login-error" className="form-error" role="alert" hidden></p>
            <button id="login-submit" className="button primary wide" type="submit">Войти</button>
            <div className="demo-accounts">
              <span className="muted">Учётные записи стенда:</span>
              <button type="button" className="chip-button" data-demo="master@kst.demo">Мастер</button>
              <button type="button" className="chip-button" data-demo="admin@kst.demo">Администратор</button>
              <button type="button" className="chip-button" data-demo="engineer@kst.demo">Инженер</button>
              <button type="button" className="chip-button" data-demo="operator@kst.demo">Оператор</button>
            </div>
          </form>
          <form id="password-form" className="login-card" noValidate hidden>
            <p className="wordmark">КСТ Визор</p>
            <h1>Смена временного пароля</h1>
            <p className="muted">Администратор ИБ выдал временный пароль. Придумайте постоянный, чтобы продолжить работу.</p>
            <label className="field">
              <span>Временный пароль</span>
              <input id="password-current" type="password" name="current" autoComplete="current-password" required />
            </label>
            <label className="field">
              <span>Новый пароль</span>
              <input id="password-new" type="password" name="new" autoComplete="new-password" required />
            </label>
            <label className="field">
              <span>Новый пароль ещё раз</span>
              <input id="password-repeat" type="password" name="repeat" autoComplete="new-password" required />
            </label>
            <p id="password-error" className="form-error" role="alert" hidden></p>
            <button id="password-submit" className="button primary wide" type="submit">Сменить пароль</button>
          </form>
        </main>

        <div id="app" className="app" hidden>
          <header className="topbar">
            <div className="topbar-title">
              <span className="wordmark">КСТ Визор</span>
              <span className="topbar-sub">пульт демонстрации</span>
            </div>
            <div className="topbar-side">
              <span id="link-state" className="link-state">Подключение к серверу</span>
              <span id="user-name" className="user-name"></span>
              <button id="logout" className="button ghost" type="button">Выйти</button>
            </div>
          </header>

          <section className="console" aria-labelledby="console-title">
            <div className="console-head">
              <div>
                <h1 id="console-title">Сценарии и время</h1>
                <p id="console-unit" className="console-unit"></p>
              </div>
              <div className="console-clock">
                <span className="console-clock-label">Время на стенде</span>
                <span id="cursor-time" className="console-clock-value">нет данных</span>
                <span id="cursor-origin" className="console-origin"></span>
              </div>
            </div>

            <p id="console-note" className="console-note" hidden></p>
            <p id="err-console" className="section-error on-dark" hidden></p>

            <div id="console-body">
              <div id="scenarios" className="scenarios" role="group" aria-label="Сценарии"></div>

              <div className="strip-wrap">
                <div id="strip" className="strip" role="slider" tabIndex={0} aria-label="Время на стенде" aria-valuemin={0} aria-valuemax={0} aria-valuenow={0}>
                  <div id="strip-bands" className="strip-bands"></div>
                  <div id="strip-needle" className="strip-needle" hidden></div>
                </div>
                <div id="strip-ticks" className="strip-ticks" aria-hidden="true"></div>
                <p className="strip-legend">
                  <span className="legend-item"><i className="legend-swatch growth"></i>рост параметра</span>
                  <span className="legend-item"><i className="legend-swatch beyond"></i>параметр за уставкой</span>
                  <span className="legend-item"><i className="legend-swatch model"></i>смоделированные данные</span>
                </p>
              </div>

              <div className="steps" role="group" aria-label="Сдвиг времени">
                <button className="step" type="button" data-step="-24">-24 ч</button>
                <button className="step" type="button" data-step="-6">-6 ч</button>
                <button className="step" type="button" data-step="-1">-1 ч</button>
                <button className="step" type="button" data-step="1">+1 ч</button>
                <button className="step" type="button" data-step="6">+6 ч</button>
                <button className="step" type="button" data-step="24">+24 ч</button>
                <button id="play" className="step play" type="button" aria-pressed="false">Пустить время: 1 час за 2 секунды</button>
              </div>
            </div>
          </section>

          <div className="layout">
            <aside className="card units" aria-labelledby="units-title">
              <h2 id="units-title">Оборудование</h2>
              <p id="err-units" className="section-error" hidden></p>
              <div id="units" className="unit-list"></div>
            </aside>

            <section className="card telemetry" aria-labelledby="telemetry-title">
              <div className="card-head">
                <h2 id="telemetry-title">Показания датчиков</h2>
                <span id="telemetry-stamp" className="muted"></span>
              </div>
              <p id="err-telemetry" className="section-error" hidden></p>
              <div id="labels" className="labels"></div>
              <div id="tiles" className="tiles"></div>

              <div className="chart-head">
                <h3 id="chart-title">График</h3>
                <div id="chart-hours" className="segmented" role="group" aria-label="Период графика">
                  <button type="button" data-hours="12">12 ч</button>
                  <button type="button" data-hours="24">24 ч</button>
                  <button type="button" data-hours="72">3 суток</button>
                  <button type="button" data-hours="168">7 суток</button>
                </div>
              </div>
              <p id="err-chart" className="section-error" hidden></p>
              <div className="chart-box">
                <canvas id="chart" aria-label="График выбранного параметра с уставками"></canvas>
              </div>
              <p id="forecast" className="forecast muted"></p>
            </section>

            <section className="card diagnosis" aria-labelledby="diagnosis-title">
              <h2 id="diagnosis-title">Текущий диагноз</h2>
              <p id="err-diagnosis" className="section-error" hidden></p>
              <div id="verdict" className="verdict"></div>
              <div id="diagnosis" className="finding-list"></div>
              <h3>Порядок осмотра узлов</h3>
              <p id="err-route" className="section-error" hidden></p>
              <ol id="route" className="route"></ol>
              <p className="decision">Решение принимает инженер.</p>
            </section>
          </div>

          <div className="lower">
            <section className="card history" aria-labelledby="history-title">
              <h2 id="history-title">История осмотров и работ</h2>
              <p id="err-history" className="section-error" hidden></p>
              <div id="history" className="history-list"></div>
            </section>

            <section className="card board" aria-labelledby="board-title">
              <div className="card-head">
                <h2 id="board-title">Замечания</h2>
                <div id="board-scope" className="segmented" role="group" aria-label="Чьи замечания показывать">
                  <button type="button" data-scope="unit">Выбранный агрегат</button>
                  <button type="button" data-scope="all">Всё оборудование</button>
                </div>
              </div>
              <p id="err-findings" className="section-error" hidden></p>
              <div className="board-columns">
                <div className="board-column">
                  <h3>Открыто <span id="count-open" className="count">0</span></h3>
                  <div id="board-open" className="board-cards"></div>
                </div>
                <div className="board-column">
                  <h3>В работе <span id="count-in_work" className="count">0</span></h3>
                  <div id="board-in_work" className="board-cards"></div>
                </div>
                <div className="board-column">
                  <h3>Устранено <span id="count-resolved" className="count">0</span></h3>
                  <div id="board-resolved" className="board-cards"></div>
                </div>
              </div>
            </section>
          </div>

          <section className="card assistant" aria-labelledby="assistant-title">
            <h2 id="assistant-title">Вопрос помощнику</h2>
            <form id="ask-form" className="ask-form">
              <input id="ask-input" type="text" maxLength={500} autoComplete="off" placeholder="Например: какие замечания не устранены" aria-label="Вопрос помощнику" />
              <button id="ask-submit" className="button primary" type="submit">Спросить</button>
            </form>
            <p id="err-assistant" className="section-error" hidden></p>
            <div id="answer" className="answer" hidden></div>
          </section>
        </div>

        <dialog id="photo-dialog" className="photo-dialog" aria-label="Снимок к замечанию">
          <img id="photo-image" alt="Стоп-кадр камеры, приложенный к замечанию" />
          <form method="dialog"><button className="button primary" type="submit">Закрыть</button></form>
        </dialog>

    </>
  );
});

/** Пульт демонстрации: разметка из React, логика подключается в браузере после её появления. */
export default function PanelApp() {
  useEffect(() => {
    if (!loading) loading = import("@/src/panel/legacy");
  }, []);
  return <Markup />;
}
