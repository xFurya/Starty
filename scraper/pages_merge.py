"""Слияние протоколов перед публикацией сайта: python3 -m scraper.pages_merge СВЕЖИЕ НАШИ

Полный сбор (update.yml) идёт минуты, и всё это время задание live.yml может записать на
gh-pages более свежие протоколы. Перед самой публикацией (под общей блокировкой,
tools/pages-lock.sh) workflow забирает с gh-pages свежие файлы в СВЕЖИЕ и вызывает это:
каждый файл турнира, который есть и у нас (НАШИ — site/data/protocols), заменяется свежим,
если свежий собран позже (поле built). Набор файлов решает полный сбор: чего у нас нет,
того не добавляем (и не удаляем). status.json — по турнирам, побеждает более поздняя проверка.
"""
import datetime as dt
import json
import os
import sys

from . import protocols as P


def _time(value):
    try:
        t = dt.datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def _later(a, b):
    """a позже b (b может быть неизвестен — тогда a, если известен a)."""
    ta, tb = _time(a), _time(b)
    return ta is not None and (tb is None or ta > tb)


def merge(fresh_dir, ours_dir, log=print):
    """→ имена файлов, замененных свежими."""
    taken = []
    if not os.path.isdir(fresh_dir) or not os.path.isdir(ours_dir):
        return taken
    for fn in sorted(os.listdir(fresh_dir)):
        if not fn.endswith(".json") or fn == P.STATUS_FILE:
            continue
        mine = P.load_doc(os.path.join(ours_dir, fn))
        fresh = P.load_doc(os.path.join(fresh_dir, fn))
        if mine is None or fresh is None or not _later(fresh.get("built"), mine.get("built")):
            continue
        with open(os.path.join(fresh_dir, fn), "rb") as f:
            P._atomic_write(os.path.join(ours_dir, fn), f.read())
        taken.append(fn)
        log(f"  протокол {fn}: на gh-pages свежее ({fresh['built']} > {mine['built']}), оставлен он")
    # status.json: по турнирам
    ours_items = P.read_status(ours_dir)
    fresh_items = P.read_status(fresh_dir)
    changed = False
    for tid, item in list(ours_items.items()):
        other = fresh_items.get(tid)
        if other and _later(other.get("checked"), item.get("checked")):
            ours_items[tid] = other
            changed = True
    if changed:
        P.write_status(ours_dir, ours_items, dt.datetime.now(dt.timezone.utc))
    return taken


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    merge(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
