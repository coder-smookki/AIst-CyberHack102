import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import "@/src/panel/panel.css";

export const metadata: Metadata = {
  title: "КСТ Визор - пульт демонстрации",
  icons: { icon: "data:," },
};

export const viewport: Viewport = { width: "device-width", initialScale: 1 };

/** Корневая разметка пульта демонстрации. */
export default function PanelLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="ru">
      <body>{children}</body>
    </html>
  );
}
