"""Миниатюры фото спортсменов: квадрат 256 px на своём сайте вместо
оригиналов по 0,3–1 МБ с чужих. Имя файла — от адреса оригинала, поэтому
готовая миниатюра не скачивается повторно. Без Pillow (и без ImageMagick)
остаётся адрес оригинала.

Кадр строится по лицу (детектор YuNet из OpenCV, модель face_yunet.onnx рядом):
голова целиком с волосами и чуть плеч, лицо по центру. Источники снимают по-разному
(портрет в рост, групповое фото, обрезанный квадрат), и кадр «по пропорциям» резал
лицо пополам. Нет OpenCV или лица не нашлось — прежний кадр по пропорциям."""
import hashlib
import io
import os
import shutil
import subprocess
import tempfile

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
    """На снимке не понять, кто это: лиц несколько или лицо слишком мелкое."""


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


def make(site, url):
    """Путь миниатюры относительно сайта или None."""
    rel = rel_path(url)
    dest = os.path.join(site, rel)
    if os.path.exists(dest):
        return rel
    try:
        raw = net.fetch(url, binary=True, timeout=40)
    except net.FetchError:
        return None
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".tmp"
    # не портрет (Викисклад) — только с найденным лицом, без кадра «по пропорциям»
    strict = "wikimedia.org" in url
    try:
        if _pil(raw, tmp, strict) or (not strict and _magick(raw, tmp)):
            os.replace(tmp, dest)
            return rel
    except Exception:
        pass
    if os.path.exists(tmp):
        os.unlink(tmp)
    return None


def prune(site, keep):
    """Убрать миниатюры, на которые больше никто не ссылается."""
    d = os.path.join(site, DIR)
    if not os.path.isdir(d):
        return 0
    n = 0
    for f in os.listdir(d):
        if f"{DIR}/{f}" not in keep:
            os.unlink(os.path.join(d, f))
            n += 1
    return n
