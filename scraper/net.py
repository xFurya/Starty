"""Сетевой слой: запросы с повторами, единый User-Agent и необязательный кэш на диске.

Кэш включается переменной окружения STARTY_CACHE=<папка> и нужен только для
отладки, чтобы не дёргать источники на каждый прогон.
"""
import hashlib
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36")

_CACHE = os.environ.get("STARTY_CACHE")


class FetchError(Exception):
    pass


def _cache_path(key):
    h = hashlib.sha1(key.encode("utf-8")).hexdigest()
    return os.path.join(_CACHE, h)


def fetch(url, data=None, headers=None, timeout=30, tries=3, binary=False):
    """GET (или POST, если передан data) с повторами. Возвращает str или bytes."""
    key = url + "|" + (json.dumps(data, sort_keys=True) if data is not None else "")
    if _CACHE:
        p = _cache_path(key)
        if os.path.exists(p):
            with open(p, "rb") as f:
                raw = f.read()
            return raw if binary else _decode(raw)
    hdrs = {"User-Agent": UA, "Accept-Language": "ru,en;q=0.8"}
    if headers:
        hdrs.update(headers)
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")
    last = None
    _throttle(url)
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, data=body, headers=hdrs)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
            if _CACHE:
                os.makedirs(_CACHE, exist_ok=True)
                with open(_cache_path(key), "wb") as f:
                    f.write(raw)
            return raw if binary else _decode(raw)
        except urllib.error.HTTPError as e:
            last = e
            if e.code in (403, 404, 410):
                break
            if e.code == 429:
                time.sleep(8 * (attempt + 1))
        except Exception as e:  # сеть, таймаут, обрыв
            last = e
        time.sleep(1.5 * (attempt + 1))
    raise FetchError(f"{url}: {last}")


_last_hit = {}


def _throttle(url, gap=0.35):
    """Не чаще одного запроса в gap секунд к одному сайту — табло организаторов
    отвечают 429 на частые запросы."""
    host = url.split("/")[2] if "://" in url else url
    wait = _last_hit.get(host, 0) + gap - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    _last_hit[host] = time.monotonic()


def _decode(raw):
    for enc in ("utf-8", "cp1251"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def is_image(url, timeout=20):
    """Отдаёт ли адрес картинку. True/False; None — проверить не удалось (сеть)."""
    for method, extra in (("HEAD", {}), ("GET", {"Range": "bytes=0-1023"})):
        _throttle(url)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, **extra}, method=method)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return (r.headers.get("Content-Type") or "").lower().startswith("image/")
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return False
            if method == "HEAD" and e.code in (400, 403, 405, 501):
                continue  # не любят HEAD — спросим первый килобайт
            return None if e.code >= 500 or e.code == 429 else False
        except Exception:
            if method == "HEAD":
                continue
            return None
    return None


def fetch_json(url, data=None, headers=None, timeout=30):
    return json.loads(fetch(url, data=data, headers=headers, timeout=timeout))


def pdf_text(url):
    """Скачивает PDF и возвращает текст с сохранением раскладки (pdftotext -layout)."""
    raw = fetch(url, binary=True, timeout=45)
    if not raw.startswith(b"%PDF"):
        raise FetchError(f"{url}: не PDF")
    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
        f.write(raw)
        path = f.name
    try:
        out = subprocess.run(["pdftotext", "-layout", path, "-"],
                             capture_output=True, timeout=60)
        if out.returncode != 0:
            raise FetchError(f"{url}: pdftotext {out.returncode}")
        return out.stdout.decode("utf-8", errors="replace")
    finally:
        os.unlink(path)
