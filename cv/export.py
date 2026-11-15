"""Экспорт обученных весов в формат для сервера или телефона.

Запуск:
    python cv/export.py <best.pt> onnx [куда.onnx] [размер_входа=640]   сервер распознавания
    python cv/export.py <best.pt> coreml             iOS
    python cv/export.py <best.pt> tflite             Android, нужен Python 3.12

Без третьего параметра файл появляется в папке weights рядом с местом запуска. Размер входа задаётся
для моделей, обученных на другом размере кадра, например RF-DETR nano на 384 px.
"""

import os
import shutil
import sys

from libreyolo import LibreYOLO


def export(weights: str, kind: str, target: str | None = None, imgsz: int = 640) -> str:
    """Экспортирует веса и при необходимости переносит результат в указанный файл."""
    path = str(LibreYOLO(weights).export(format=kind, imgsz=imgsz))
    if target:
        os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
        shutil.move(path, target)
        path = target
    return path


if __name__ == "__main__":
    print(
        export(
            sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None, int(sys.argv[4]) if len(sys.argv) > 4 else 640
        )
    )
