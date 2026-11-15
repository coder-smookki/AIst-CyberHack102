"""Сборка небольшого тестового набора фотографий дефектов промышленного оборудования.

Используется только стандартная библиотека. Запуск: python3 -I build_testset.py <команда>

Команды:
  search [пул ...]   поиск на Wikimedia Commons, результат в _work/candidates.json
  datasets           малая выборка из открытых архивов через HTTP Range (без полной загрузки)
  previews [n]       загрузка уменьшенных копий первых n кандидатов каждого пула для просмотра
  build              загрузка отобранных снимков (selection.tsv) и запись manifest.csv
  rebuild            повторная загрузка всех файлов из manifest.csv
  verify             сверка manifest.csv с файлами на диске

Отбор делается глазами по контактным листам (make_contact_sheets.py). Источники,
которые отказывают автоматическому доступу (401, 403, 451), пропускаются без обхода.
Загруженные файлы считаются недоверенными данными: они только сохраняются на диск.
"""

import csv
import html
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

UA = "research-dataset-builder/1.0"
ROOT = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(ROOT, "_work")
IMG = os.path.join(ROOT, "images")
MANIFEST = os.path.join(ROOT, "manifest.csv")
SELECTION = os.path.join(ROOT, "selection.tsv")
CANDIDATES = os.path.join(WORK, "candidates.json")
QUERY_LOG = os.path.join(WORK, "query_log.tsv")
SLEEP = 0.3
MIN_LONG_SIDE = 500
MAX_LONG_SIDE = 1600
PER_QUERY = 20
PER_POOL = 120
MEMBER = "::member="
FIELDS = ["file", "class", "source", "page_url", "download_url", "licence", "author", "width", "height", "note"]
CLASSES = [
    "corrosion",
    "leak",
    "burnt_electrical",
    "bolt_defect",
    "guard_missing",
    "guard_ok",
    "motor_damage",
    "insulation_damage",
    "crack",
    "gauge",
    "nameplate",
    "equipment_ok",
]

COMMONS_QUERIES = {
    "corrosion": [
        "rusty pump",
        "corroded flange",
        "corroded valve",
        "rusty valve",
        "rusty pipe flange",
        "rusty gate valve",
        "rusty electric motor",
        "corroded pipe",
        "corrosion pipeline flange",
        "corroded pump",
        "Korrosion Pumpe",
        "Korrosion Flansch",
        "rostige Pumpe",
        "verrostetes Ventil",
        "verrostetes Rohr",
        "ржавый насос",
        "ржавая задвижка",
        "коррозия трубопровода",
        "ржавая труба фланец",
        'incategory:"Rust" pump',
        'incategory:"Rust" valve',
        'incategory:"Corrosion" pipe',
        'incategory:"Corrosion" flange',
    ],
    "leak": [
        "oil leak pump",
        "leaking valve",
        "leaking pipe flange",
        "leaking pump",
        "leaking pump seal",
        "water leak pipe",
        "oil leak machine",
        "leaking mechanical seal",
        "leaking gland packing",
        "steam leak valve",
        "hydraulic oil leak",
        "pipe leak drip",
        "undichte Pumpe",
        "Leckage Rohr",
        "Ölleck",
        "tropfendes Ventil",
        "undichter Flansch",
        "утечка масла",
        "течь трубы",
        "протечка трубы",
        "течь задвижки",
        'incategory:"Leaks" pipe',
        'incategory:"Oil leaks"',
        "leaking pipe",
        "leaking flange",
        "dripping pipe",
        "pipe leak",
        "oil leak",
        "water leak",
        "leaking valve stem",
        "leak clamp pipe",
        'incategory:"Leaks"',
        'incategory:"Water leaks"',
        "Leckage",
        "течь",
    ],
    "gauge": [
        "pressure gauge",
        "Manometer",
        "манометр",
        "bourdon gauge",
        "pressure gauge pump",
        "Druckmanometer",
        'incategory:"Pressure gauges"',
    ],
    "nameplate": [
        "electric motor nameplate",
        "Typenschild Elektromotor",
        "pump nameplate",
        "шильдик электродвигателя",
        "motor rating plate",
        "Typenschild Pumpe",
        "Typenschild Motor",
        "rating plate electric motor",
        "Typenschild Drehstrommotor",
    ],
    "equipment_ok": [
        "centrifugal pump",
        "Inline-Pumpe",
        "circulation pump",
        "Kreiselpumpe",
        "Umwälzpumpe",
        "Grundfos pump",
        "electric motor industrial",
        "Drehstrommotor",
        "gate valve",
        "центробежный насос",
        "Heizungspumpe",
    ],
    "burnt_electrical": [
        "burnt terminal block",
        "burnt electrical connector",
        "overheated cable",
        "burnt wire",
        "melted cable insulation",
        "burnt contactor",
        "burnt fuse holder",
        "verschmortes Kabel",
        "Kabelbrand",
        "оплавленный кабель",
    ],
    "bolt_defect": [
        "rusty bolts",
        "corroded bolt",
        "missing bolt",
        "rusty anchor bolt",
        "rusty flange bolts",
        "broken bolt",
    ],
    "coupling": [
        "shaft coupling",
        "coupling guard",
        "pump coupling",
        "flexible coupling pump motor",
        "Wellenkupplung",
        "Kupplungsschutz",
    ],
    "crack": [
        "cracked pipe",
        "cracked weld",
        "weld crack",
        "fatigue crack steel",
        "Rohrbruch",
        "трещина трубы",
        "cracked casting",
    ],
    "insulation_damage": [
        "damaged pipe insulation",
        "pipe lagging",
        "pipe insulation",
        "Rohrisolierung",
        "теплоизоляция труб",
        "теплотрасса изоляция",
    ],
    "motor_damage": [
        "damaged electric motor",
        "broken electric motor",
        "old electric motor",
        "electric motor fan cover",
    ],
}

EXCLUDE = re.compile(
    r"locomotiv|lokomotiv|dampflok|steam engine|dampfmaschine|паровоз|museum|"
    r"musée|музей|\bship\b|schiff|wreck|wrack|\bcars?\b|automobil|\bauto\b|"
    r"motorcycle|motorrad|bicycle|fahrrad|tractor|traktor|diagram|drawing|"
    r"schema|logo|\bmap\b|karte|icon|\.svg|engraving|patent|coat of arms|"
    r"gas station|petrol|fuel pump|tankstelle|hand pump|water pump at|"
    r"village pump|windmill|aircraft|airplane|flugzeug|самол[её]т|"
    r"fire hydrant|hydrant",
    re.I,
)

DATASETS = {
    "zn_ostrava": {
        "source": "zenodo",
        "pool": "corrosion",
        "url": "https://zenodo.org/api/records/11235637/files/" "corrosion-in-industrial-complexes-in-ostrava.zip/content",
        "page_url": "https://zenodo.org/records/11235637",
        "licence": "CC BY 4.0",
        "author": "Frič, Matěj (Zenodo 11235637)",
        "samples": [(r"/images/[^/]+\.jpg$", 15)],
    },
    "md_bolts": {
        "source": "mendeley",
        "pool": "bolt_defect",
        "url": "https://data.mendeley.com/public-files/datasets/cxnj6cp4rb/files/"
        "8227ae89-9e21-4880-ae64-f150c10180df/file_downloaded",
        "page_url": "https://data.mendeley.com/datasets/cxnj6cp4rb/1",
        "licence": "CC BY 4.0",
        "author": "Jafari, Faezeh; Dorafshan, Sattar (Mendeley cxnj6cp4rb)",
        "samples": [
            (r"Loosen bolt.*/Resized images 640-640/[^/]+\.(jpg|jpeg|png)$", 10),
            (r"Missing bolt.*/Resized- 640-640/[^/]+\.(jpg|jpeg|png)$", 10),
        ],
    },
}


class Refused(Exception):
    """Сайт отказал автоматическому доступу; элемент пропускается."""


_last_request = [0.0]


def _open(url, headers=None, timeout=90, retries=4):
    """Открывает URL с вежливой паузой и ограниченным числом повторов.

    Ответы 429 и 5xx повторяются после Retry-After, если пауза не больше 60 с.
    Ответы 401, 403, 451 и 429 с длинной паузой превращаются в Refused.
    """
    hdrs = {"User-Agent": UA}
    hdrs.update(headers or {})
    err = None
    for attempt in range(retries):
        wait = SLEEP - (time.time() - _last_request[0])
        if wait > 0:
            time.sleep(wait)
        _last_request[0] = time.time()
        try:
            return urllib.request.urlopen(urllib.request.Request(url, headers=hdrs), timeout=timeout)
        except urllib.error.HTTPError as e:
            err = e
            if e.code in (401, 403, 451):
                raise Refused("HTTP %d for %s" % (e.code, url))
            if e.code in (429, 500, 502, 503, 504) and attempt < retries - 1:
                ra = e.headers.get("Retry-After", "")
                if ra.isdigit() and int(ra) > 60:
                    raise Refused("HTTP %d, Retry-After %s for %s" % (e.code, ra, url))
                time.sleep(int(ra) if ra.isdigit() else 5 * (attempt + 1))
                continue
            raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            err = e
            time.sleep(3 * (attempt + 1))
    raise err


def http_bytes(url, headers=None, timeout=90, retries=4):
    """Возвращает тело ответа целиком."""
    with _open(url, headers, timeout, retries) as r:
        return r.read()


def http_json(url):
    """Возвращает разобранный JSON-ответ."""
    return json.loads(http_bytes(url).decode("utf-8"))


def image_size(data):
    """Возвращает (ширина, высота, расширение) для JPEG или PNG, иначе None."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", data[16:24])
        return w, h, "png"
    if data[:2] != b"\xff\xd8":
        return None
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker == 0xFF:
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        seglen = struct.unpack(">H", data[i + 2 : i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            h, w = struct.unpack(">HH", data[i + 5 : i + 9])
            return w, h, "jpg"
        i += 2 + seglen
    return None


def clean(text, limit=120):
    """Убирает HTML-разметку и лишние пробелы, обрезает до limit символов."""
    text = html.unescape(re.sub(r"<[^>]+>", " ", text or ""))
    return re.sub(r"\s+", " ", text).strip()[:limit]


def load_candidates():
    """Читает словарь кандидатов из _work/candidates.json."""
    if os.path.exists(CANDIDATES):
        with open(CANDIDATES, encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_candidates(cands):
    """Атомарно записывает словарь кандидатов."""
    os.makedirs(WORK, exist_ok=True)
    tmp = CANDIDATES + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cands, f, ensure_ascii=False, indent=1)
    os.replace(tmp, CANDIDATES)


def commons_search(query, limit=PER_QUERY):
    """Ищет файлы на Wikimedia Commons и возвращает пригодных кандидатов.

    Отбрасываются не JPEG/PNG, снимки меньше MIN_LONG_SIDE, файлы без
    лицензии и заголовки из списка исключений (чертежи, техника, музеи).
    Файлы уже 1280 px отдаются только как оригиналы с upload.wikimedia.org,
    где автоматическим клиентам отвечают 429, поэтому они тоже пропускаются.
    """
    params = {
        "action": "query",
        "format": "json",
        "generator": "search",
        "gsrnamespace": "6",
        "gsrsearch": query,
        "gsrlimit": str(limit),
        "prop": "imageinfo",
        "iiprop": "url|extmetadata|size|mime",
        "iiurlwidth": "1280",
        "iiextmetadatafilter": "LicenseShortName|Artist|ImageDescription",
    }
    url = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params)
    pages = http_json(url).get("query", {}).get("pages", {})
    out = []
    for p in sorted(pages.values(), key=lambda x: x.get("index", 0)):
        ii = (p.get("imageinfo") or [{}])[0]
        meta = ii.get("extmetadata", {})
        licence = clean(meta.get("LicenseShortName", {}).get("value", ""), 60)
        title = p.get("title", "")
        if ii.get("mime") not in ("image/jpeg", "image/png"):
            continue
        if max(ii.get("width", 0), ii.get("height", 0)) < MIN_LONG_SIDE:
            continue
        if not licence or not ii.get("thumburl") or EXCLUDE.search(title):
            continue
        thumb = ii["thumburl"].split("?")[0]
        if "/thumb/" not in thumb:
            continue
        out.append(
            {
                "id": "cm%d" % p["pageid"],
                "source": "commons",
                "title": title,
                "desc": clean(meta.get("ImageDescription", {}).get("value", ""), 200),
                "page_url": ii.get("descriptionurl", ""),
                "download_url": thumb,
                "preview_url": re.sub(r"/\d+px-", "/330px-", thumb),
                "licence": licence,
                "author": clean(meta.get("Artist", {}).get("value", "")) or "unknown",
                "width": ii.get("thumbwidth", 0),
                "height": ii.get("thumbheight", 0),
            }
        )
    return out


def cmd_search(args):
    """Выполняет запросы по пулам и пополняет список кандидатов.

    Кандидаты набираются по кругу из всех запросов пула, чтобы каждый
    запрос дал свои лучшие результаты. Журнал запросов пишется в query_log.tsv.
    """
    cands = load_candidates()
    os.makedirs(WORK, exist_ok=True)
    seen = set(cands)
    with open(QUERY_LOG, "a", encoding="utf-8") as log:
        for pool, queries in COMMONS_QUERIES.items():
            if args and pool not in args:
                continue
            per_query = []
            for q in queries:
                try:
                    hits, status = commons_search(q), "ok"
                except Refused as e:
                    hits, status = [], "refused: %s" % e
                except Exception as e:
                    hits, status = [], "error: %s" % e
                new = [h for h in hits if h["id"] not in seen]
                log.write("commons\t%s\t%s\t%d\t%d\t%s\n" % (pool, q, len(hits), len(new), status))
                print("%-18s %-40s hits=%2d new=%2d %s" % (pool, q, len(hits), len(new), "" if status == "ok" else status))
                for h in new:
                    h["query"] = q
                    seen.add(h["id"])
                per_query.append(new)
            have = sum(1 for c in cands.values() if c["pool"] == pool)
            rank = 0
            while have < PER_POOL and any(len(x) > rank for x in per_query):
                for hits in per_query:
                    if len(hits) > rank and have < PER_POOL:
                        hits[rank]["pool"] = pool
                        cands[hits[rank]["id"]] = hits[rank]
                        have += 1
                rank += 1
            save_candidates(cands)
    print("candidates:", len(cands))


class HttpRangeFile(io.RawIOBase):
    """Файл на удалённом сервере с произвольным доступом через HTTP Range."""

    def __init__(self, url, block=1 << 20):
        """Определяет конечный адрес после перенаправления и размер файла."""
        super().__init__()
        self.block = block
        with _open(url, {"Range": "bytes=0-0"}) as r:
            self.url = r.geturl()
            self.size = int(r.headers["Content-Range"].split("/")[1])
        self.pos = 0
        self.cache_start = 0
        self.cache = b""

    def readable(self):
        """Файл доступен для чтения."""
        return True

    def seekable(self):
        """Файл поддерживает перемещение."""
        return True

    def tell(self):
        """Текущая позиция."""
        return self.pos

    def seek(self, offset, whence=0):
        """Перемещает позицию чтения."""
        self.pos = offset + (0, self.pos, self.size)[whence]
        return self.pos

    def read(self, n=-1):
        """Читает n байт, запрашивая у сервера блок не меньше block."""
        if n is None or n < 0:
            n = self.size - self.pos
        n = min(n, self.size - self.pos)
        if n <= 0:
            return b""
        lo = self.pos - self.cache_start
        if not (0 <= lo and lo + n <= len(self.cache)):
            end = min(self.size, self.pos + max(n, self.block)) - 1
            self.cache = http_bytes(self.url, {"Range": "bytes=%d-%d" % (self.pos, end)})
            self.cache_start = self.pos
            lo = 0
        data = self.cache[lo : lo + n]
        self.pos += len(data)
        return data


_zip_cache = {}


def remote_zip(url):
    """Открывает удалённый zip-архив без полной загрузки."""
    if url not in _zip_cache:
        _zip_cache[url] = zipfile.ZipFile(HttpRangeFile(url))
    return _zip_cache[url]


def fetch(download_url):
    """Возвращает байты по адресу из манифеста.

    Обычный адрес загружается целиком. Адрес вида
    <адрес архива>::member=<путь> означает один файл удалённого zip-архива.
    """
    if MEMBER in download_url:
        url, member = download_url.split(MEMBER, 1)
        return remote_zip(url).read(urllib.parse.unquote(member))
    return http_bytes(download_url)


def spread(items, n):
    """Возвращает n элементов, равномерно распределённых по отсортированному списку."""
    items = sorted(items)
    if len(items) <= n:
        return items
    step = len(items) / float(n)
    return [items[int(i * step)] for i in range(n)]


def cmd_datasets(args):
    """Регистрирует малую детерминированную выборку из открытых архивов.

    Читается только оглавление архива; сами файлы загружаются позже по одному.
    """
    cands = load_candidates()
    for key, ds in DATASETS.items():
        if args and key not in args:
            continue
        try:
            names = [i.filename for i in remote_zip(ds["url"]).infolist() if not i.is_dir()]
        except Refused as e:
            print(key, "refused, skipped:", e)
            continue
        picks = []
        for pattern, n in ds["samples"]:
            rx = re.compile(pattern, re.I)
            picks += spread([m for m in names if rx.search(m)], n)
        for k, member in enumerate(picks, 1):
            cid = "%s_%03d" % (key, k)
            dl = ds["url"] + MEMBER + urllib.parse.quote(member)
            cands[cid] = {
                "id": cid,
                "source": ds["source"],
                "title": member,
                "desc": "",
                "page_url": ds["page_url"],
                "download_url": dl,
                "preview_url": dl,
                "licence": ds["licence"],
                "author": ds["author"],
                "width": 0,
                "height": 0,
                "pool": ds["pool"],
                "query": key,
            }
        print(key, "members:", len(names), "sampled:", len(picks))
        save_candidates(cands)


def cmd_previews(args):
    """Загружает уменьшенные копии кандидатов в _work/previews/<пул>/.

    Аргументы: необязательное число n (первые n кандидатов Commons в пуле)
    и необязательные имена пулов. Выборки из архивов загружаются всегда.
    Миниатюра Commons, которую сервер не отдал за 15 с, пропускается.
    """
    limit = int(args[0]) if args and args[0].isdigit() else 10**6
    pools = [a for a in args if not a.isdigit()]
    count = {}
    done = failed = 0
    for c in load_candidates().values():
        if pools and c["pool"] not in pools:
            continue
        if c["source"] == "commons":
            if "/thumb/" not in c["download_url"]:
                continue
            count[c["pool"]] = count.get(c["pool"], 0) + 1
            if count[c["pool"]] > limit:
                continue
        d = os.path.join(WORK, "previews", c["pool"])
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, c["id"] + ".img")
        if os.path.exists(path):
            continue
        try:
            if c["source"] == "commons":
                data = http_bytes(c["preview_url"], None, 15, 1)
            else:
                data = fetch(c["preview_url"])
            if not image_size(data):
                raise ValueError("not a JPEG/PNG")
            with open(path, "wb") as f:
                f.write(data)
            done += 1
        except Exception as e:
            failed += 1
            print("preview failed", c["id"], str(e)[:100])
    print("previews downloaded:", done, "failed:", failed)


def shrink(path):
    """Уменьшает снимок до MAX_LONG_SIDE по длинной стороне утилитой sips.

    Затрагивает только снимки с длинной стороной больше MAX_LONG_SIDE:
    оригиналы из архивов и вертикальные кадры Commons. Если sips нет
    (не macOS), файл остаётся без изменений.
    """
    with open(path, "rb") as f:
        size = image_size(f.read())
    if size and max(size[0], size[1]) > MAX_LONG_SIDE and shutil.which("sips"):
        subprocess.run(
            ["sips", "-Z", str(MAX_LONG_SIDE), path], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        with open(path, "rb") as f:
            size = image_size(f.read())
    return size


def write_manifest(rows):
    """Записывает manifest.csv, упорядочив строки по классу и имени файла."""
    rows = sorted(rows, key=lambda r: (CLASSES.index(r["class"]), r["file"]))
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    os.replace(tmp, MANIFEST)


def read_manifest():
    """Читает строки manifest.csv."""
    if not os.path.exists(MANIFEST):
        return []
    with open(MANIFEST, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def cmd_build(args):
    """Загружает отобранные снимки и записывает manifest.csv.

    selection.tsv содержит строки: идентификатор кандидата, класс, примечание.
    Уже загруженные файлы и полноразмерные копии из previews не запрашиваются снова.
    """
    cands = load_candidates()
    rows = []
    seen = set()
    with open(SELECTION, encoding="utf-8") as f:
        selection = [ln.rstrip("\n").split("\t") for ln in f if ln.strip()]
    for cid, cls, note in selection:
        if cid in seen:
            continue
        seen.add(cid)
        c = cands[cid]
        os.makedirs(os.path.join(IMG, cls), exist_ok=True)
        local = [p for p in (os.path.join(IMG, cls, cid + e) for e in (".jpg", ".png")) if os.path.exists(p)]
        preview = os.path.join(WORK, "previews", c["pool"], cid + ".img")
        try:
            if local:
                with open(local[0], "rb") as fh:
                    data = fh.read()
            elif c["preview_url"] == c["download_url"] and os.path.exists(preview):
                with open(preview, "rb") as fh:
                    data = fh.read()
            else:
                data = fetch(c["download_url"])
            size = image_size(data)
            if not size or max(size[0], size[1]) < MIN_LONG_SIDE:
                raise ValueError("not JPEG/PNG or too small: %r" % (size,))
        except Exception as e:
            print("SKIP", cid, e)
            continue
        rel = "images/%s/%s.%s" % (cls, cid, size[2])
        path = os.path.join(ROOT, rel)
        if not local:
            with open(path, "wb") as fh:
                fh.write(data)
        size = shrink(path)
        rows.append(
            {
                "file": rel,
                "class": cls,
                "source": c["source"],
                "page_url": c["page_url"],
                "download_url": c["download_url"],
                "licence": c["licence"],
                "author": c["author"],
                "width": size[0],
                "height": size[1],
                "note": note,
            }
        )
    write_manifest(rows)
    print("manifest rows:", len(rows), "of", len(seen))


def cmd_rebuild(args):
    """Загружает заново все файлы манифеста, которых нет на диске."""
    ok = bad = 0
    for r in read_manifest():
        path = os.path.join(ROOT, r["file"])
        if os.path.exists(path):
            ok += 1
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            data = fetch(r["download_url"])
            if not image_size(data):
                raise ValueError("not a JPEG/PNG")
            with open(path, "wb") as f:
                f.write(data)
            shrink(path)
            ok += 1
        except Exception as e:
            bad += 1
            print("FAILED", r["file"], e)
    print("present:", ok, "failed:", bad)


def cmd_verify(args):
    """Сверяет манифест с диском и печатает число снимков по классам."""
    rows = read_manifest()
    listed = set()
    problems = 0
    counts = {}
    for r in rows:
        listed.add(r["file"])
        path = os.path.join(ROOT, r["file"])
        if not os.path.exists(path):
            print("MISSING", r["file"])
            problems += 1
            continue
        with open(path, "rb") as f:
            size = image_size(f.read())
        if not size or (str(size[0]), str(size[1])) != (r["width"], r["height"]):
            print("SIZE MISMATCH", r["file"], size, r["width"], r["height"])
            problems += 1
        if not (r["licence"] and r["page_url"] and r["download_url"] and r["author"]):
            print("INCOMPLETE ROW", r["file"])
            problems += 1
        counts[r["class"]] = counts.get(r["class"], 0) + 1
    for d, _, files in os.walk(IMG):
        for fn in files:
            rel = os.path.relpath(os.path.join(d, fn), ROOT).replace(os.sep, "/")
            if rel not in listed and not fn.startswith("."):
                print("NOT IN MANIFEST", rel)
                problems += 1
    for cls in CLASSES:
        print("%-18s %3d" % (cls, counts.get(cls, 0)))
    print("total %d, problems %d" % (len(rows), problems))
    return 1 if problems else 0


COMMANDS = {
    "search": cmd_search,
    "datasets": cmd_datasets,
    "previews": cmd_previews,
    "build": cmd_build,
    "rebuild": cmd_rebuild,
    "verify": cmd_verify,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    sys.exit(COMMANDS[sys.argv[1]](sys.argv[2:]) or 0)
