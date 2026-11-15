import type { NextConfig } from "next";

/**
 * Сборка веб-панели и пульта демонстрации в статические файлы: сервер FastAPI раздаёт папку out
 * по адресам /web/, /panel/ и /_next/, поэтому интернет и отдельный сервер Node не нужны.
 */
const nextConfig: NextConfig = {
  output: "export",
  trailingSlash: true,
  reactStrictMode: true,
  poweredByHeader: false,
  productionBrowserSourceMaps: false,
  images: { unoptimized: true },
  devIndicators: false,
};

export default nextConfig;
