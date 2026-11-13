"""Обучение детектора узлов и дефектов на размеченном наборе.

Запуск:
    python cv/train.py <data.yaml> [эпохи=30] [веса=LibreYOLO9t.pt] [устройство=mps]

Устройство: mps для Apple Silicon, 0 для видеокарты NVIDIA, cpu в остальных случаях.
Код и стартовые веса распространяются по лицензии MIT.
"""
import sys
import time

from libreyolo import LibreYOLO


def main() -> None:
    """Запускает обучение и печатает путь к лучшим весам."""
    data = sys.argv[1]
    epochs = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    weights = sys.argv[3] if len(sys.argv) > 3 else "LibreYOLO9t.pt"
    device = sys.argv[4] if len(sys.argv) > 4 else "mps"
    started = time.time()
    model = LibreYOLO(weights)
    model.train(data=data, epochs=epochs, imgsz=640, batch=16, device=device, workers=4,
                project="runs", name="detector", exist_ok=True)
    print(f"готово за {(time.time() - started) / 60:.1f} мин: runs/detector/weights/best.pt")


if __name__ == "__main__":
    main()
