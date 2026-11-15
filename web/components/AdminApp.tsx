"use client";

import { memo, useEffect, useState } from "react";
import Assistant from "./Assistant";

let loading: Promise<void> | null = null;

/** Подключает модули веб-панели один раз за жизнь страницы. */
function loadPanel(): Promise<void> {
  if (!loading) loading = import("@/src/admin/legacy").then(() => undefined);
  return loading;
}

/**
 * Узел #app, в котором веб-панель рисует оболочку и страницы. React создаёт его один раз и больше не
 * перерисовывает, чтобы не мешать живому обновлению страниц.
 */
const Root = memo(function Root() {
  return <div id="app" className="scr wscr" data-theme="light" suppressHydrationWarning />;
});

/** Веб-панель: оболочка по ролям из модулей панели и помощник администратора поверх неё. */
export default function AdminApp() {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let alive = true;
    loadPanel().then(() => {
      if (alive) setReady(true);
    });
    return () => {
      alive = false;
    };
  }, []);
  return (
    <>
      <Root />
      {ready ? <Assistant /> : null}
    </>
  );
}
