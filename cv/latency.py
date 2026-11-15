"""Замер времени обработки одного кадра моделью ONNX на этом компьютере.

Запуск:
    python cv/latency.py <модель.onnx> [повторов=60] [отчёт.json]

Замеряется только работа сети в ONNX Runtime на процессоре и через CoreML, без чтения кадра и отрисовки.
"""

import json
import os
import statistics
import sys
import time

import numpy as np
import onnxruntime


def measure(path: str, provider: str, repeats: int = 60) -> dict:
    """Возвращает медиану и 90-й процентиль времени вывода в миллисекундах для одного поставщика."""
    session = onnxruntime.InferenceSession(path, providers=list(dict.fromkeys([provider, "CPUExecutionProvider"])))
    feeds = {}
    for item in session.get_inputs():
        shape = [
            side if isinstance(side, int) and side > 0 else (1 if index == 0 else 640) for index, side in enumerate(item.shape)
        ]
        kind = np.float32 if "float" in item.type else np.int64
        feeds[item.name] = np.random.rand(*shape).astype(kind) if kind is np.float32 else np.full(shape, 640, kind)
    for _ in range(8):
        session.run(None, feeds)
    times = []
    for _ in range(repeats):
        started = time.perf_counter()
        session.run(None, feeds)
        times.append((time.perf_counter() - started) * 1000)
    times.sort()
    return {
        "provider": session.get_providers()[0],
        "median_ms": round(statistics.median(times), 1),
        "p90_ms": round(times[int(len(times) * 0.9)], 1),
        "input": {name: list(value.shape) for name, value in feeds.items()},
    }


def main() -> None:
    """Замеряет модель на процессоре и через CoreML и печатает результат."""
    path = sys.argv[1]
    repeats = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    report = {"model": os.path.basename(path), "size_mb": round(os.path.getsize(path) / 1e6, 1), "runs": []}
    for provider in ("CPUExecutionProvider", "CoreMLExecutionProvider"):
        if provider in onnxruntime.get_available_providers():
            try:
                report["runs"].append(measure(path, provider, repeats))
            except Exception as error:
                report["runs"].append({"provider": provider, "error": str(error)[:200]})
    if len(sys.argv) > 3:
        json.dump(report, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
