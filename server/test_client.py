"""Замер полного круга «кадр ушёл, рамки пришли» на кадрах из папки.

Запуск:
    python server/test_client.py ws://127.0.0.1:8000/ws/detect <папка_с_jpg> <токен_доступа>

Токен доступа выдаёт POST /auth/login; он добавляется к адресу соединения параметром token.
"""

import asyncio
import glob
import json
import sys
import time
from pathlib import Path
from urllib.parse import urlencode

import websockets


async def main(url: str, folder: str, token: str) -> None:
    """Отправляет кадры по одному и печатает медиану и 95-й процентиль времени ответа."""
    frames = [Path(path).read_bytes() for path in sorted(glob.glob(folder + "/*.jpg"))[:60]]
    if not frames:
        raise SystemExit(f"В папке {folder} нет кадров JPEG")
    address = url + ("&" if "?" in url else "?") + urlencode({"token": token})
    async with websockets.connect(address, max_size=None) as socket:
        for frame in frames[:5]:
            await socket.send(frame)
            await socket.recv()
        trips, inference, boxes = [], [], 0
        for frame in frames:
            started = time.perf_counter()
            await socket.send(frame)
            reply = json.loads(await socket.recv())
            if reply.get("type") != "frame":
                raise SystemExit(f"Сервер ответил: {reply}")
            trips.append((time.perf_counter() - started) * 1000)
            inference.append(reply["ms"])
            boxes += len(reply["boxes"])
    trips.sort()
    median = trips[len(trips) // 2]
    print(
        f"кадров {len(frames)}: круг медиана {median:.1f} мс, p95 {trips[int(len(trips) * 0.95)]:.1f} мс, "
        f"модель {sum(inference) / len(inference):.1f} мс, рамок {boxes}, около {1000 / median:.0f} кадров/с"
    )


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3]))
