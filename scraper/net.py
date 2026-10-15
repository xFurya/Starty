"""Сетевой слой: запросы с повторами, единый User-Agent и необязательный кэш на диске.

Кэш включается переменной окружения STARTY_CACHE=<папка> и нужен только для
отладки, чтобы не дёргать источники на каждый прогон.
"""
import hashlib
import json
import os
import socket
import subprocess
import re
import tempfile
import time
import urllib.error
import urllib.request
from urllib.parse import quote, urlsplit, urlunsplit

UA =("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36")

# Викимедиа просит у роботов честное имя и адрес проекта, иначе отвечает 429
BOT_UA = "StartyBot/1.0 (https://github.com/xFurya/Starty) python-urllib"


def _ua(url):
    return BOT_UA if re.search(r"//[^/]*(wikimedia|wikidata|wikipedia)\.org/", url) else UA


_CACHE = os.environ.get("STARTY_CACHE")


class FetchError(Exception):
    """Табло или сеть не ответили нужным образом.

    kind: http (код в status), timeout (таймаут), net (нет связи, обрыв), format (ответ пришёл,
    но это не то, что ждём: не PDF, pdftotext не разобрал). status — HTTP-код или None.
    Текст сообщения тот же, что и раньше."""

    def __init__(self, message, kind="net", status=None):
        super().__init__(message)
        self.kind = kind
        self.status = status


def _error_kind(exc):
    """(kind, status) для исключения из urlopen."""
    if isinstance(exc, urllib.error.HTTPError):
        return "http", exc.code
    if isinstance(exc, (socket.timeout, TimeoutError)):
        return "timeout", None
    if isinstance(exc, urllib.error.URLError) and isinstance(exc.reason, (socket.timeout, TimeoutError)):
        return "timeout", None
    return "net", None


def _cache_path(key):
    h = hashlib.sha1(key.encode("utf-8")).hexdigest()
    return os.path.join(_CACHE, h)


def ascii_url(url):
    """Кириллический домен — в punycode, кириллица в пути — в %-кодировку: urllib иначе падает на latin-1."""
    p = urlsplit(url)
    if p.hostname and not p.hostname.isascii():
        netloc = p.hostname.encode("idna").decode("ascii")
        if p.port:
            netloc += f":{p.port}"
        p = p._replace(netloc=netloc)
    return urlunsplit(p._replace(
        path=quote(p.path, safe="/%:@!$&'()*+,;=-._~"),
        query=quote(p.query, safe="%=&+:/?;,.-_~!$'()*@"),
    ))


def fetch(url, data=None, headers=None, timeout=30, tries=3, binary=False):
    """GET (или POST, если передан data) с повторами. Возвращает str или bytes."""
    key = url + "|" + (json.dumps(data, sort_keys=True) if data is not None else "")
    if _CACHE:
        p = _cache_path(key)
        if os.path.exists(p):
            with open(p, "rb") as f:
                raw = f.read()
            return raw if binary else _decode(raw)
    hdrs = {"User-Agent": _ua(url), "Accept-Language": "ru,en;q=0.8"}
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
            req = urllib.request.Request(ascii_url(url), data=body, headers=hdrs)
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
    kind, status = _error_kind(last)
    raise FetchError(f"{url}: {last}", kind=kind, status=status)


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
            req = urllib.request.Request(url, headers={"User-Agent": _ua(url), **extra}, method=method)
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
        raise FetchError(f"{url}: не PDF", kind="format")
    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
        f.write(raw)
        path = f.name
    try:
        out = subprocess.run(["pdftotext", "-layout", path, "-"],
                             capture_output=True, timeout=60)
        if out.returncode != 0:
            raise FetchError(f"{url}: pdftotext {out.returncode}", kind="format")
        return out.stdout.decode("utf-8", errors="replace")
    finally:
        os.unlink(path)
