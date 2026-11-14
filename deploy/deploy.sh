#!/usr/bin/env bash
set -euo pipefail

HOST="${KST_HOST:-kct}"
REMOTE="${KST_DIR:-/opt/kst-vizor}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"

OCR_FILES=(PP-OCRv6_det_small.onnx ch_ppocr_mobile_v2.0_cls_mobile.onnx PP-OCRv6_rec_small.onnx)
ocr_source() {
    if [ -f "$ROOT/models/ocr/${OCR_FILES[0]}" ]; then
        echo "$ROOT/models/ocr"
        return
    fi
    "$ROOT/.venv/bin/python" -c "import pathlib, rapidocr; print(pathlib.Path(rapidocr.__file__).parent / 'models')"
}

mkdir -p "$STAGE/src/deploy" "$STAGE/src/models/ocr" "$STAGE/src/data/customer"
cp -p "$ROOT/requirements.txt" "$STAGE/src/"
cp -p "$ROOT/deploy/Dockerfile" "$STAGE/src/deploy/"
cp -p "$ROOT/deploy/.dockerignore" "$STAGE/src/.dockerignore"
rsync -a --exclude '__pycache__' --exclude '.DS_Store' "$ROOT/server" "$STAGE/src/"
mkdir -p "$STAGE/src/cv"
cp -p "$ROOT/cv/nameplate.py" "$ROOT/cv/gauge.py" "$STAGE/src/cv/"
cp -p "$ROOT/models/detector.onnx" "$ROOT/models/defects.onnx" "$ROOT/models/models.json" "$STAGE/src/models/"
OCR_DIR="$(ocr_source)"
for name in "${OCR_FILES[@]}"; do
    cp -p "$OCR_DIR/$name" "$STAGE/src/models/ocr/"
done
cp -p "$ROOT/data/equipment.json" "$ROOT/data/rules.json" "$STAGE/src/data/"
for folder in "Вибрация" "Температура"; do
    mkdir -p "$STAGE/src/data/customer/$folder"
    find "$ROOT/data/customer/$folder" -maxdepth 1 -name '*.xlsx' -exec cp -p {} "$STAGE/src/data/customer/$folder/" \;
done
cp -p "$ROOT/deploy/docker-compose.yml" "$ROOT/deploy/Caddyfile" "$STAGE/"

ssh "$HOST" "mkdir -p '$REMOTE' && cd '$REMOTE' && if [ ! -f .env ]; then umask 077; printf 'KST_GATE=%s\n' \"\$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')\" > .env; fi"
rsync -a --delete --exclude '/.env' "$STAGE/" "$HOST:$REMOTE/"

ssh "$HOST" "cd '$REMOTE' && docker compose up -d --build --remove-orphans && docker image prune -f >/dev/null"

for _ in $(seq 1 30); do
    if ssh "$HOST" "docker inspect -f '{{.State.Health.Status}}' kst-vizor-app" 2>/dev/null | grep -q healthy; then
        ssh "$HOST" "cd '$REMOTE' && docker compose ps"
        exit 0
    fi
    sleep 5
done
echo "Сервер не стал готов за 150 секунд, журнал: ssh $HOST 'docker logs --tail 100 kst-vizor-app'" >&2
exit 1
