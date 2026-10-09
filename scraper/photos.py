"""Миниатюры фото спортсменов: квадрат 256 px на своём сайте вместо
оригиналов по 0,3–1 МБ с чужих. Имя файла — от адреса оригинала, поэтому
готовая миниатюра не скачивается повторно. Без Pillow (и без ImageMagick)
остаётся адрес оригинала."""
import hashlib
import io
import os
import shutil
import subprocess
import tempfile

from . import net

SIZE = 256
DIR = "photos"


def rel_path(url):
    return f"{DIR}/{hashlib.sha1(url.encode('utf-8')).hexdigest()[:16]}.jpg"


def _box(w, h):
    # квадрат на 90 % короткой стороны: по центру по ширине, у верха по высоте —
    # лицо на портретах сборной и ISU в верхней половине кадра
    side = int(min(w, h) * 0.9)
    left = (w - side) // 2
    top = int((h - side) * 0.1)
    return left, top, side


def _pil(raw, dest):
    try:
        from PIL import Image
    except ImportError:
        return False
    im = Image.open(io.BytesIO(raw))
    im = im.convert("RGB")
    left, top, side = _box(*im.size)
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
    try:
        if _pil(raw, tmp) or _magick(raw, tmp):
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
