#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/deploy/.local-build"
rm -rf "$STAGE"
mkdir -p "$STAGE/src/deploy" "$STAGE/src/models/ocr" "$STAGE/src/data/customer" "$STAGE/src/cv"

OCR_FILES=(PP-OCRv6_det_small.onnx ch_ppocr_mobile_v2.0_cls_mobile.onnx PP-OCRv6_rec_small.onnx)
if [ -f "$ROOT/models/ocr/${OCR_FILES[0]}" ]; then
    OCR_DIR="$ROOT/models/ocr"
else
    OCR_DIR="$("$ROOT/.venv/bin/python" -c "import pathlib, rapidocr; print(pathlib.Path(rapidocr.__file__).parent / 'models')")"
fi

cp -p "$ROOT/requirements.txt" "$STAGE/src/"
cp -p "$ROOT/deploy/Dockerfile" "$STAGE/src/deploy/"
cp -p "$ROOT/deploy/.dockerignore" "$STAGE/src/.dockerignore"
rsync -a --exclude '__pycache__' --exclude '.DS_Store' "$ROOT/server" "$STAGE/src/"
cp -p "$ROOT/cv/nameplate.py" "$ROOT/cv/gauge.py" "$STAGE/src/cv/"
cp -p "$ROOT"/models/*.onnx "$ROOT/models/models.json" "$STAGE/src/models/"
for name in "${OCR_FILES[@]}"; do cp -p "$OCR_DIR/$name" "$STAGE/src/models/ocr/"; done
cp -p "$ROOT/data/equipment.json" "$ROOT/data/rules.json" "$STAGE/src/data/"
for folder in "Вибрация" "Температура"; do
    mkdir -p "$STAGE/src/data/customer/$folder"
    find "$ROOT/data/customer/$folder" -maxdepth 1 -name '*.xlsx' -exec cp -p {} "$STAGE/src/data/customer/$folder/" \;
done
cp -p "$ROOT/deploy/docker-compose.local.yml" "$STAGE/"

cd "$STAGE"
docker compose -f docker-compose.local.yml up -d --build
for _ in $(seq 1 40); do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' kst-vizor-local 2>/dev/null)" = "healthy" ]; then
        docker compose -f docker-compose.local.yml ps
        exit 0
    fi
    sleep 5
done
echo "Сервер не стал готов, журнал: docker logs --tail 100 kst-vizor-local" >&2
exit 1
