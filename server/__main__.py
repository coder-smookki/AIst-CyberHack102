"""Запуск сервера «КСТ Визор» в локальной сети: python -m server [--port 8000] [--host 0.0.0.0]."""
import argparse
import logging

import uvicorn

from server.app import create_app


def main(argv: list[str] | None = None) -> None:
    """Разбирает параметры командной строки и запускает сервер."""
    parser = argparse.ArgumentParser(prog="python -m server", description="Сервер КСТ Визор")
    parser.add_argument("--host", default="0.0.0.0", help="адрес, на котором слушает сервер (по умолчанию 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8000, help="порт сервера (по умолчанию 8000)")
    parser.add_argument("--log-level", default="info", choices=("debug", "info", "warning", "error"),
                        help="подробность журнала сервера")
    options = parser.parse_args(argv)
    if not 1 <= options.port <= 65535:
        parser.error("порт должен быть от 1 до 65535")
    logging.basicConfig(level=options.log_level.upper(), format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    uvicorn.run(create_app(), host=options.host, port=options.port, log_level=options.log_level)


if __name__ == "__main__":
    main()
