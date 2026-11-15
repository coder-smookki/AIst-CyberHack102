"""Запись models/models.json: перечень моделей, которые сервер загружает вместе.

Запуск:
    python cv/manifest.py <папка_models> <роль>=<файл.onnx>[=<описание.json>] [...]

Роль: stand (узлы и дефекты макета) или defects (дефекты на реальных снимках). Классы и размер входа
читаются из самого файла ONNX, поэтому запись не может разойтись с моделью. Необязательный файл
описания добавляет к записи сведения о семействе, лицензии весов, данных обучения и замерах.
"""

import json
import os
import sys

import onnxruntime

ROLES = ("stand", "defects")
NODE_CLASSES = ("motor", "pump_casing", "flange", "coupling_guard", "terminal_box", "nameplate", "gauge")
CONF_CHECK, CONF_DEFECT = 0.25, 0.5


def entry(folder: str, role: str, file: str, extra: dict | None = None) -> dict:
    """Собирает запись об одной модели по метаданным файла ONNX."""
    if role not in ROLES:
        raise ValueError(f"неизвестная роль модели: {role}")
    session = onnxruntime.InferenceSession(os.path.join(folder, file), providers=["CPUExecutionProvider"])
    meta = session.get_modelmeta().custom_metadata_map
    names = json.loads(meta["names"])
    classes = [names[str(index)] for index in range(len(names))]
    row = {
        "file": file,
        "role": role,
        "classes": classes,
        "imgsz": int(meta["imgsz"]),
        "defect_classes": [name for name in classes if name not in NODE_CLASSES],
        "conf_check": CONF_CHECK,
        "conf_defect": CONF_DEFECT,
        "input": session.get_inputs()[0].name,
        "size_mb": round(os.path.getsize(os.path.join(folder, file)) / 1e6, 1),
    }
    row.update(extra or {})
    return row


def main() -> None:
    """Записывает models.json для перечисленных моделей и печатает его."""
    folder, entries = sys.argv[1], []
    for item in sys.argv[2:]:
        role, file, *rest = item.split("=")
        extra = json.load(open(rest[0], encoding="utf-8")) if rest else None
        entries.append(entry(folder, role, file, extra))
    json.dump(entries, open(os.path.join(folder, "models.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(entries, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
