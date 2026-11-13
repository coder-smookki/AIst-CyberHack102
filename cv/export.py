"""Экспорт обученных весов в формат для сервера или телефона.

Запуск:
    python cv/export.py <best.pt> onnx      сервер распознавания
    python cv/export.py <best.pt> coreml    iOS
    python cv/export.py <best.pt> tflite    Android, нужен Python 3.12

Файлы появляются в папке weights рядом с местом запуска.
"""
import sys

from libreyolo import LibreYOLO

if __name__ == "__main__":
    print(LibreYOLO(sys.argv[1]).export(format=sys.argv[2], imgsz=640))
