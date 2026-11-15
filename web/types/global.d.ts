/** Объекты веб-панели, которые модули оформления кладут в window. */
export {};

declare global {
  interface Window {
    KV?: KvLib;
    WA?: WebAdmin;
  }

  /** Библиотека оформления: значки и экранирование. */
  interface KvLib {
    ICONS: Record<string, string>;
    esc(s: unknown): string;
  }

  /** Сотрудник, вошедший в панель. */
  interface WebUser {
    id: string | number;
    name: string;
    role: string;
    permissions: string[];
    must_change_password?: boolean;
  }

  /** Основа веб-панели: сеанс, обращения к API, переходы между страницами. */
  interface WebAdmin {
    root: HTMLElement;
    user: WebUser | null;
    pages: Record<string, { full?: boolean; guard?: () => boolean }>;
    api<T = unknown>(method: string, path: string, body?: unknown): Promise<T>;
    post<T = unknown>(path: string, body?: unknown): Promise<T>;
    go(key: string, params?: Record<string, unknown>): void;
    current(): { key: string; params: Record<string, unknown> } | null;
    hasWeb(): boolean;
    reload(): void;
    copy(text: string): Promise<boolean>;
    toast(title: string, text?: string, kind?: string, icon?: string): void;
  }
}
