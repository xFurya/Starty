"""Миниатюры фото спортсменов: квадрат 256 px на своём сайте вместо
оригиналов по 0,3–1 МБ с чужих. Имя файла — от адреса оригинала, поэтому
готовая миниатюра не скачивается повторно. Без Pillow (и без ImageMagick)
остаётся адрес оригинала.

Кадр строится по лицу (детектор YuNet из OpenCV, модель face_yunet.onnx рядом):
голова целиком с волосами и чуть плеч, лицо по центру. Источники снимают по-разному
(портрет в рост, групповое фото, обрезанный квадрат), и кадр «по пропорциям» резал
лицо пополам. Нет OpenCV или лица не нашлось — прежний кадр по пропорциям.

Найденное не пропадает. Что уже нашли, записано в data/photos.json (человек → файл, откуда, из какого
источника) и лежит в site/photos. Сбой сети, пустой ответ источника, пропавший
профиль ISU или битая картинка прежнего фото не убирают; заменить его можно только снимком из
более надёжного источника, и только когда новая миниатюра благополучно собрана. Адрес в
photo_skip.json попадает только за то, что на снимке нельзя понять, кто это, — не за сбой сети."""
import hashlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import time

from . import names as nm
from . import net

SIZE = 256
DIR = "photos"


# версия нарезки: при смене все миниатюры делаются заново (имя файла от неё зависит)
CUT = "4"


def rel_path(url):
    return f"{DIR}/{hashlib.sha1((CUT + url).encode('utf-8')).hexdigest()[:16]}.jpg"


def _box(w, h):
    # Портрет выше, чем шире (ISU: голова с волосами сверху и плечи): берём всю ширину и кадр
    # чуть выше середины — вся голова от макушки до подбородка. Квадратные фото (сборная) — 90 %.
    if h > w * 1.08:
        side = w
        top = int((h - side) * 0.3)
        return 0, top, side
    side = int(min(w, h) * 0.9)
    left = (w - side) // 2
    top = int((h - side) * 0.1)
    return left, top, side


_MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "face_yunet.onnx")


class Unsure(Exception):
    """На снимке не понять, кто это, или это не портрет: лиц несколько, лицо мелкое, головной убор,
    размытость. Текст — причина для photo_skip."""


# Версия правил портретного контроля (QUALITY_V в записи книги: снимок уже проверен этими правилами)
QUALITY_V = "3"
LAP_MIN = 80.0          # дисперсия Лапласиана миниатюры 256 px: ниже — размыто
FACE_MIN = 0.18         # ширина лица / ширина кадра после кадрирования
FACE_MAX_CY = 2 / 3     # центр лица не ниже двух третей кадра
EYES_MIN = 0.25         # расстояние между глазами / ширина лица: меньше — профиль или поворот
FOREHEAD_MIN = 0.05     # доля кожи на лбу: меньше — лоб закрыт (шапка, капюшон, чёлка до бровей)
HAT_WIDTH = 1.6         # светлая однотонная полоса над лицом шире 1.6 ширин лица и не от края до края — шапка


def portrait_problem(im):
    """Причина отказа (строка) или None. im — PIL RGB, уже вырезанный кадр (миниатюра).
    Нет OpenCV — проверить нечем, отказа нет (но и новых снимков из Викисклада без неё не берём)."""
    try:
        import cv2
        import numpy as np
    except ImportError:
        return None
    arr = cv2.cvtColor(np.asarray(im.convert("RGB").resize((SIZE, SIZE))), cv2.COLOR_RGB2BGR)
    try:
        det = cv2.FaceDetectorYN.create(_MODEL, "", (SIZE, SIZE), 0.75)
        _, faces = det.detect(arr)
    except cv2.error:
        return None
    if faces is None or not len(faces):
        return "лица нет"
    faces = sorted(faces, key=lambda f: f[2] * f[3] * f[14], reverse=True)
    f = faces[0]
    if len(faces) > 1 and faces[1][2] * faces[1][3] >= 0.2 * f[2] * f[3]:
        return "лиц несколько"
    x, y, w, h = (float(v) for v in f[:4])
    if w / SIZE < FACE_MIN:
        return "лицо мелкое в кадре"
    if (y + h / 2) / SIZE > FACE_MAX_CY:
        return "лицо в нижней трети кадра"
    if abs(f[6] - f[4]) / w < EYES_MIN:
        return "не анфас"
    gray = cv2.cvtColor(arr, cv2.COLOR_BGR2GRAY)
    if cv2.Laplacian(gray, cv2.CV_64F).var() < LAP_MIN:
        return "размыто"
    # лоб: полоса над линией глаз между глазами
    eye_y = (f[5] + f[7]) / 2
    dist = abs(f[6] - f[4])
    ya, yb = int(max(0, eye_y - 1.0 * dist)), int(max(1, eye_y - 0.35 * dist))
    xa, xb = int(max(0, min(f[4], f[6]))), int(min(SIZE, max(f[4], f[6])))
    strip = cv2.cvtColor(arr, cv2.COLOR_BGR2YCrCb)[ya:yb, xa:xb]
    skin = 1.0
    if strip.size:
        skin = float(((strip[..., 1] > 133) & (strip[..., 1] < 180) & (strip[..., 2] > 77) & (strip[..., 2] < 135)).mean())
    # светлая нейтральная (мех, белая шапка) полоса над лицом
    hsv = cv2.cvtColor(arr, cv2.COLOR_BGR2HSV)
    r0, r1 = int(max(0, y - 0.35 * h)), int(max(1, y - 0.05 * h))
    band = hsv[r0:r1]
    light = ((band[..., 2] > 170) & (band[..., 1] < 70)).mean(0) > 0.5 if band.size else np.zeros(SIZE, bool)
    best = cur = start = best_start = 0
    for i, v in enumerate(light):
        if v:
            if cur == 0:
                start = i
            cur += 1
            if cur > best:
                best, best_start = cur, start
        else:
            cur = 0
    spans_edge = best_start == 0 or best_start + best >= SIZE - 1
    if skin < 0.25 and best / w > HAT_WIDTH and not spans_edge:
        return "головной убор"
    if skin < FOREHEAD_MIN:
        return "лоб закрыт"
    return None


def _face(im, strict=False):
    """(x, y, w, h) самого заметного лица на снимке или None. strict — снимок не портрет
    (Викисклад: прокат, пьедестал, пара): лицо должно быть одно и крупное, иначе Unsure."""
    try:
        import cv2
        import numpy as np
    except ImportError:
        if strict:
            raise Unsure("нет OpenCV")
        return None
    w, h = im.size
    k = min(1.0, 640 / max(w, h))
    small = im.resize((max(1, int(w * k)), max(1, int(h * k)))) if k < 1 else im
    arr = cv2.cvtColor(np.asarray(small), cv2.COLOR_RGB2BGR)
    try:
        det = cv2.FaceDetectorYN.create(_MODEL, "", (arr.shape[1], arr.shape[0]), 0.75)
        _, faces = det.detect(arr)
    except cv2.error:
        return None
    if faces is None or not len(faces):
        if strict:
            raise Unsure("лица нет")
        return None
    faces = sorted(faces, key=lambda f: f[2] * f[3] * f[14], reverse=True)
    f = faces[0]
    if strict:
        if len(faces) > 1 and faces[1][2] * faces[1][3] >= 0.2 * f[2] * f[3]:
            raise Unsure("лиц несколько")
        if max(f[2], f[3]) / k < 64:
            raise Unsure("лицо мелкое")
    return tuple(float(v) / k for v in f[:4])


def face_box(w, h, face):
    """Квадрат вокруг лица: сторона — 2,6 лица, сверху запас под волосы (0,55 лица),
    снизу — подбородок и плечи. Не выходит за снимок."""
    fx, fy, fw, fh = face
    f = max(fw, fh)
    side = min(w, h, max(f * 2.6, 96))
    cx = fx + fw / 2
    top = fy - f * 0.55
    # кадр меньше нужного (лицо крупно) — центр по лицу
    if side < f * 2.6:
        top = fy + fh / 2 - side / 2
    left = int(round(min(max(cx - side / 2, 0), w - side)))
    top = int(round(min(max(top, 0), h - side)))
    return left, top, int(side)


def _pil(raw, dest, strict=False):
    try:
        from PIL import Image, ImageOps
    except ImportError:
        return False
    im = Image.open(io.BytesIO(raw))
    im = ImageOps.exif_transpose(im).convert("RGB")
    face = _face(im, strict)
    left, top, side = face_box(*im.size, face) if face else _box(*im.size)
    im = im.crop((left, top, left + side, top + side)).resize((SIZE, SIZE), Image.LANCZOS)
    if strict:
        why = portrait_problem(im)
        if why:
            raise Unsure(why)
    im.save(dest, "JPEG", quality=84, optimize=True, progressive=True)
    return True


def _magick(raw, dest):
    exe = shutil.which("magick") or shutil.which("convert")
    if not exe:
        return False
    with tempfile.NamedTemporaryFile(suffix=".img", delete=False) as f:
        f.write(raw)
        src = f.name
    try:
        w, h = map(int, subprocess.check_output(
            [shutil.which("identify") or "identify", "-format", "%w %h", src + "[0]"], text=True).split())
        left, top, side = _box(w, h)
        subprocess.check_call([exe, src + "[0]", "-auto-orient", "-crop", f"{side}x{side}+{left}+{top}",
                               "+repage", "-resize", f"{SIZE}x{SIZE}", "-strip", "-quality", "84",
                               "-interlace", "JPEG", dest])
        return True
    finally:
        os.unlink(src)




def have(site, url):
    return os.path.exists(os.path.join(site, rel_path(url)))


def _wiki(url):
    return "wikimedia.org" in url


# Сайты, к которым ходим не чаще раза в секунду: Викисклад, ФФККР, ISU
_POLITE = ("wikimedia.org", "wikidata.org", "fsrussia.ru", "isuresults.com", "isu-skating.com", "front-api.isu.org")


def _polite(url):
    host = url.split("/")[2] if "://" in url else ""
    if any(h in host for h in _POLITE):
        net._throttle(url, gap=1.0)


def source_url(url):
    """Что скачивать. В словарях адрес Викисклада с width=500 (по нему назван файл миниатюры), но лицо
    на 500 px бывает мельче 64 px и снимок зря отбраковывался (Синицына): берём 960 (размер из списка Викимедиа: нестандартные размеры они отвечают 429)."""
    return url.replace("width=500", "width=960") if _wiki(url) else url


REASONS = {}  # адрес → причина отбраковки в этом сборе (для photo_skip)


def make2(site, url):
    """(путь миниатюры относительно сайта или None, итог): ok; unsure — на снимке не понять, кто это
    (только Викисклад), такой адрес больше не пробуем; fail — сеть, битый файл или нечем обработать,
    адрес в порядке, повторим в следующий раз."""
    rel = rel_path(url)
    dest = os.path.join(site, rel)
    if os.path.exists(dest):
        return rel, "ok"
    _polite(url)
    try:
        raw = net.fetch(source_url(url), binary=True, timeout=40)
    except net.FetchError:
        return None, "fail"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".tmp"
    # не портрет (Викисклад) — только с найденным лицом, без кадра «по пропорциям»
    strict = _wiki(url)
    status = "fail"
    try:
        if _pil(raw, tmp, strict) or (not strict and _magick(raw, tmp)):
            if os.path.getsize(tmp) > 800:  # пустой или обрезанный файл — не фото
                os.replace(tmp, dest)
                return rel, "ok"
    except Unsure as e:
        status = "unsure"
        REASONS[url] = str(e)
    except Exception:
        pass
    if os.path.exists(tmp):
        os.unlink(tmp)
    return None, status


def make(site, url):
    """Путь миниатюры относительно сайта или None."""
    return make2(site, url)[0]


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOK = os.path.join(ROOT, "data", "photos.json")


def prune(site, keep, book_path=None):
    """Убрать миниатюры, на которые больше никто не ссылается. Всё, что записано в памяти о найденном
    (data/photos.json), остаётся, даже если человека сейчас нет в списках: потеря информации хуже лишних 12 КБ."""
    d = os.path.join(site, DIR)
    if not os.path.isdir(d):
        return 0
    keep = set(keep) | {e.get("f") for e in load_book(book_path or BOOK).values() if isinstance(e, dict)}
    n = 0
    for f in os.listdir(d):
        if f"{DIR}/{f}" not in keep:
            os.unlink(os.path.join(d, f))
            n += 1
    return n


# ---------------------------------------------------------------- память о найденном

def load_book(path):
    """{ключ человека: {f: файл или адрес, u: откуда, p: приоритет источника, c: версия нарезки}}"""
    try:
        with open(path, encoding="utf-8") as f:
            book = json.load(f).get("photos")
    except (OSError, ValueError, AttributeError):
        return {}
    return book if isinstance(book, dict) else {}


def save_book(path, book):
    """Записать раздел «photos» (остальное в файле, если оно там есть, не трогаем)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    data["photos"] = book
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=0, sort_keys=True)
    os.replace(tmp, path)


SICK_AFTER = 6  # столько отказов подряд — сайт на этот сбор откладываем
WIKI_PRIO = 3  # с этого приоритета — Викиданные/Викисклад: строгий контроль личности и портрета
BOOT_PRIO = 3  # приоритет фото, о котором память ничего не знает
SKIP_V = "3|"  # версия правил отбраковки; «2|» — прежние (лиц несколько, мелкое) — всё ещё действуют
SKIP_OLD = ("2|",)
WHY = " # "  # адрес и причина в одной строке: «3|адрес # причина»


def _skip_rows(path):
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return {}
    out = {}
    for x in raw if isinstance(raw, list) else ():
        if isinstance(x, str) and x.startswith((SKIP_V,) + SKIP_OLD):
            url, _, why = x[len(SKIP_V):].partition(WHY)
            out[url] = why
    return out


def load_skip(path):
    return set(_skip_rows(path))


def save_skip(path, urls, reasons=None):
    """urls — адреса (или «person:<ключ>» — человек без подтверждённой личности); reasons — {адрес: причина}."""
    old = _skip_rows(path)
    reasons = reasons or {}
    rows = []
    for u in urls:
        why = reasons.get(u) or old.get(u)
        rows.append(SKIP_V + u + (WHY + why if why else ""))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(sorted(rows), f, ensure_ascii=False, indent=0)


def thumb_problem(site, rel):
    """Причина отказа готовой миниатюры или None (файл не открылся — тоже None: это сбой, не снимок)."""
    try:
        from PIL import Image
        with Image.open(os.path.join(site, rel)) as im:
            im.load()
            return portrait_problem(im)
    except Exception:
        return None


def _alive(site, f):
    return bool(f) and (f.startswith("http") or os.path.exists(os.path.join(site, f)))


class Sources:
    """Адреса фото по имени. Сначала точное совпадение ключа, потом грубая свёртка написаний
    (Rubtsova = Rubcova), потом «почти то же имя» — только если кандидат ровно один и это не
    имя другого человека из списка."""

    def __init__(self, raw, names, wanted):
        self.rows = {}   # ключ → [(приоритет, адрес)]
        self.labels = {}  # ключ → подпись
        for label, url, prio in raw:
            ru = names.to_ru(label)
            k = nm.key(ru)
            if k:
                self.rows.setdefault(k, []).append((prio, url))
                self.labels.setdefault(k, ru)
        self.fold = {}
        for k, label in self.labels.items():
            p = nm._parts(label)
            if p:
                self.fold.setdefault(p, []).append(k)
        self.wanted = {nm.key(names.to_ru(n)): names.to_ru(n) for n in wanted}
        self.near_by_first = {}
        for k, label in self.labels.items():
            p = nm._parts(label)
            if p and k not in self.wanted:  # подпись, которая сама есть в списке, — чужое фото
                self.near_by_first.setdefault((p[0][:1], p[1][:1]), []).append(k)
        self.names = names

    def find(self, name):
        """[(приоритет, адрес)] по возрастанию приоритета."""
        ru = self.names.to_ru(name)
        k = nm.key(ru)
        keys = [k] if k in self.rows else []
        if not keys:
            p = nm._parts(ru)
            others = {pp for kk, pp in ((kk, nm._parts(v)) for kk, v in self.wanted.items()) if kk != k and pp}
            if p and p not in others:
                keys = [x for x in self.fold.get(p, []) if x not in self.wanted or x == k]
            if not keys and p:
                hits = [x for x in self.near_by_first.get((p[0][:1], p[1][:1]), ())
                        if nm.near(ru, self.labels[x])]
                if len(hits) == 1:
                    keys = hits
        out = []
        for x in keys:
            out.extend(self.rows[x])
        return sorted(out, key=lambda t: t[0])


def collect(site, want, raw, prev_photos, names, book_path, skip_path, log=print, is_image=None, wiki_ok=True):
    """{«Имя Фамилия»: путь миниатюры или адрес} для всех из want.

    raw — [(имя из источника, адрес, приоритет)], чем меньше приоритет, тем надёжнее источник.
    Не из личного профиля ISU и не из сборной (приоритет ≥ 3, Викисклад): запись книги держится,
    только если её адрес есть среди подтверждённых личностью (people.wikidata_photos) и миниатюра
    прошла портретный контроль текущей версии (поле q). Иначе запись убирается, адрес — в photo_skip
    с причиной; файл остаётся до prune следующего сбора. wiki_ok=False (Викиданные не ответили) —
    подтверждённых нет по сбою, а не по существу: ничего не убираем.

    Найденное не теряется: у кого фото уже есть (в data/photos.json, на сайте, в прошлом
    events.json), оно остаётся, пока не найдётся снимок из более надёжного источника и его миниатюра
    не получится целиком. Сеть не ответила — прежнее фото остаётся."""
    is_image = is_image or net.is_image
    book = load_book(book_path)
    skip = load_skip(skip_path)
    src = Sources(raw, names, want)
    checked = {}
    out = {}
    stats = {"kept": 0, "new": 0, "upgraded": 0, "unsure": 0, "net": 0, "dropped": 0}
    reasons = {}

    sick = {}  # сайт → сколько подряд запросов не ответили

    def host(url):
        return url.split("/")[2] if "://" in url else ""

    def down(url):
        """Сайт ответил отказом (Викисклад отвечает 429 при частых запросах) несколько раз подряд —
        до конца сбора его не трогаем: прежние фото остаются, остальное доберётся в следующий раз."""
        return sick.get(host(url), 0) >= SICK_AFTER

    def note(url, ok):
        h = host(url)
        sick[h] = 0 if ok else sick.get(h, 0) + 1

    def usable(url):
        """True/False — адрес отдаёт картинку или нет; None — проверить не удалось."""
        if url not in checked:
            _polite(url)
            checked[url] = is_image(url)
        return checked[url]

    for n in want:
        k = nm.key(names.to_ru(n))
        entry = book.get(k)
        if entry and not _alive(site, entry.get("f")):
            book.pop(k, None)  # файл пропал с диска: показывать нечего, ищем заново
            entry = None
        prev = prev_photos.get(n)
        if not entry and prev and _alive(site, prev) and f"person:{k}" not in skip:
            # было в прошлом сборе, а в памяти нет: берём как есть; источник неизвестен — считаем
            # ISU-уровнем, Викиданные его не перебьют
            entry = {"f": prev, "u": "", "p": BOOT_PRIO, "c": CUT if not prev.startswith("http") else ""}
        if entry and entry.get("p", 0) >= WIKI_PRIO and entry.get("q") != QUALITY_V:
            urls = {u for _, u in src.find(n)}
            why = None
            if not entry.get("u") or entry["u"] not in urls:
                if wiki_ok:
                    why = "личность не подтверждена (нет среди проверенных по году рождения)"
            else:
                why = thumb_problem(site, entry["f"])
                if not why:
                    entry["q"] = QUALITY_V
            if why:
                key = entry.get("u") or f"person:{k}"
                skip.add(key)
                reasons[key] = why
                book.pop(k, None)
                entry = None
                stats["dropped"] += 1
        got = None
        for prio, url in src.find(n):
            if url in skip:
                continue
            if entry and not (prio < entry["p"] or (url == entry["u"] and entry["c"] != CUT)):
                continue  # уже есть не хуже — ради этого сеть не трогаем
            if have(site, url):
                got = (prio, url, rel_path(url))
                break
            if down(url):
                stats["net"] += 1
                continue
            if usable(url) is False:  # None — проверить не удалось (429 на HEAD), сама загрузка решит
                continue
            rel, status = make2(site, url)
            note(url, status != "fail")
            if status == "fail":
                stats["net"] += 1
            if rel:
                got = (prio, url, rel)
                break
            if status == "unsure":
                skip.add(url)
                if url in REASONS:
                    reasons[url] = REASONS[url]
                stats["unsure"] += 1
            elif not entry and not _wiki(url):
                got = (prio, url, url)  # миниатюру не собрать — пока адрес оригинала
                break
        if got:
            stats["new" if not entry else "kept" if got[2] == entry["f"] else "upgraded"] += 1
            prio, url, rel = got
            book[k] = {"f": rel, "u": url, "p": prio, "c": "" if rel.startswith("http") else CUT}
            if prio >= WIKI_PRIO and not rel.startswith("http"):
                book[k]["q"] = QUALITY_V  # make2 строгий для Викисклада: правила уже применены
        elif entry:
            stats["kept"] += 1
            book[k] = entry
        if k in book:
            out[n] = book[k]["f"]
    save_book(book_path, book)
    save_skip(skip_path, skip, reasons)
    keep = set(out.values()) | {e["f"] for e in book.values() if e.get("f")}
    gone = prune(site, keep, book_path)
    local = sum(1 for v in out.values() if not v.startswith("http"))
    log(f"  фото: {len(out)} из {len(want)}, миниатюр {local}; новых {stats['new']}, заменено на лучшее "
        f"{stats['upgraded']}; не понять кто на снимке {stats['unsure']}; убрано по новым правилам {stats['dropped']}"
        + (f"; источник не ответил {stats['net']}" if stats["net"] else "")
        + (f"; убрано лишних {gone}" if gone else ""))
    return out
