"""Отпечаток набора моделей: короткий хэш файлов весов и порогов, с которыми сервер распознаёт кадры.

Отпечаток считается один раз при запуске сервера по файлам, перечисленным в models/models.json (сколько бы
их там ни было), и по полям описания, влияющим на вывод: классы, пороги, размер входа, правила отбора рамок.
Пояснительные поля описания (замеры, лицензии, заметки) в отпечаток не входят. Отпечаток сохраняется в
каждой новой находке и печатается в отчётах, чтобы по находке было видно, каким набором моделей она получена.
Пути к файлам наружу не отдаются: только имена файлов и их хэши.
"""
import hashlib
import json
from datetime import datetime
from functools import lru_cache
from pathlib import Path

MODELS_DIR = Path(__file__).resolve().parents[1] / "models"
MANIFEST = "models.json"
DEFAULT_MODEL = "detector.onnx"
SHORT = 12
CHUNK = 1024 * 1024
SEMANTIC_KEYS = ("file", "role", "classes", "defect_classes", "imgsz", "input", "conf_check", "conf_defect",
                 "thresholds", "hint", "only", "rename", "min_share")


def _entries(models_dir: Path) -> tuple[list[dict], bool]:
    """Записи моделей из models.json и признак того, что описание прочитано; без описания - одна модель по умолчанию."""
    manifest = models_dir / MANIFEST
    try:
        with open(manifest, encoding="utf-8") as file:
            document = json.load(file)
    except (OSError, ValueError):
        return [{"file": DEFAULT_MODEL}], False
    entries = document.get("models", []) if isinstance(document, dict) else document
    listed = []
    for entry in entries if isinstance(entries, list) else []:
        entry = entry if isinstance(entry, dict) else {"file": entry}
        name = entry.get("file")
        if isinstance(name, str) and name.endswith(".onnx") and Path(name).name == name:
            listed.append({key: entry[key] for key in SEMANTIC_KEYS if key in entry})
    return (listed, True) if listed else ([{"file": DEFAULT_MODEL}], False)


def _file_hash(path: Path) -> str | None:
    """SHA-256 содержимого файла; файла нет или он не читается - None."""
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as file:
            for block in iter(lambda: file.read(CHUNK), b""):
                digest.update(block)
    except OSError:
        return None
    return digest.hexdigest()


def compute(models_dir: Path | str = MODELS_DIR) -> dict:
    """Считает отпечаток набора моделей папки.

    Возвращает {fingerprint, algorithm, manifest, models: [{file, sha256, present}], computed_at}; fingerprint -
    первые 12 знаков SHA-256 от канонической записи файлов, их хэшей и полей вывода.
    """
    models_dir = Path(models_dir)
    entries, manifest = _entries(models_dir)
    models, canonical = [], []
    for entry in entries:
        full = _file_hash(models_dir / entry["file"])
        models.append({"file": entry["file"], "sha256": full[:SHORT] if full else None, "present": full is not None})
        canonical.append({**entry, "sha256": full})
    text = json.dumps(canonical, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return {"fingerprint": hashlib.sha256(text.encode("utf-8")).hexdigest()[:SHORT], "algorithm": "sha256",
            "manifest": manifest, "models": models, "computed_at": datetime.now().isoformat(timespec="seconds")}


@lru_cache(maxsize=1)
def current() -> dict:
    """Отпечаток поставленного набора моделей; считается один раз за время работы сервера."""
    return compute(MODELS_DIR)


def short() -> str:
    """Короткий отпечаток поставленного набора моделей для находок и отчётов."""
    return current()["fingerprint"]
