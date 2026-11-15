import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import "@/src/admin/css/app.css";
import "@/src/admin/css/web.css";
import "@/src/admin/css/panel.css";
import "@/src/admin/css/assistant.css";

export const metadata: Metadata = {
  title: "КСТ Визор · веб-панель",
  icons: { icon: "/web/assets/kst_mark_180.png" },
};

export const viewport: Viewport = { width: "device-width", initialScale: 1 };

/** Корневая разметка веб-панели: язык страницы, стили оформления и шрифты из сборки. */
export default function AdminLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="ru">
      <body>{children}</body>
    </html>
  );
}
