"""Снимок разбора табло на сохранённых страницах: python3 -m unittest scraper.test_protocols

Фикстуры — scraper/fixtures/protocol/<семейство>/: страницы и PDF в том виде, в каком их отдали
табло (cp1251 не перекодируем). expected.json рядом — что видит разборщик на каждой странице.
Снимок меняется только осознанно, с объяснением в коммите:
    STARTY_REGEN=1 python3 -m unittest scraper.test_protocols
перезаписывает expected.json текущим разборщиком. Без STARTY_REGEN тест сравнивает и падает
при любом расхождении. Сеть не нужна: адреса страниц подставляются из FAMILIES.
"""
import glob
import json
import os
import re
import unittest
from unittest import mock

from . import build as b
from . import net
from . import swisstiming as st

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "protocol")

# Адрес оглавления каждого семейства: по нему разрешаются относительные ссылки на страницы.
FAMILIES = {
    "denistenmemorial": {"src": "https://www.denistenmemorial.kz/results/index.htm", "offset": None},
    "ffkm": {"src": "https://ffkm.ru/results/2026-2027/2026-08-24_pm/index.htm", "offset": b.MSK_OFFSET},
    "fsrussia": {"src": "https://fsrussia.ru/results/2627/1etap_jun/index.htm", "offset": None},
    "isu": {"src": "https://results.isu.org/results/season2627/jgptur2026/index.htm", "offset": None},
}


def _read(path):
    """Страница как её отдал сервер: сначала UTF-8, иначе cp1251 (как net._decode)."""
    with open(path, "rb") as f:
        raw = f.read()
    for enc in ("utf-8", "cp1251"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    raise AssertionError(f"{path}: не декодируется")


def _base(url):
    return url.rsplit("/", 1)[-1] if url else None


def _index_view(idx):
    return {
        "name": idx["name"], "city": idx["city"], "nation": idx["nation"], "venue": idx["venue"],
        "offset": idx["offset"], "final_marks": idx["final_marks"],
        "categories": [{
            "name": c["name"],
            "entries": _base(c["entries_url"]),
            "results": _base(c["results_url"]),
            "segments": [{
                "name": s["name"],
                "page": _base(s["url"]),
                "times_pdf": _base(s["times_pdf"]),
                "judges_pdf": _base(s["judges_pdf"]),
                "final": s["final"],
                "start": s["start"].isoformat() if s.get("start") else None,
            } for s in c["segments"]],
        } for c in idx["categories"]],
    }


def snapshot(family):
    """Что текущий разборщик говорит о каждой странице семейства (только то, что он умеет)."""
    spec = FAMILIES[family]
    base = spec["src"].rsplit("/", 1)[0] + "/"
    d = os.path.join(FIX, family)
    out = {"index": {}, "segments": {}, "totals": {}}
    for path in sorted(glob.glob(os.path.join(d, "*.htm*"))):
        name = os.path.basename(path)
        text = _read(path)
        if re.fullmatch(r"index[\w]*\.html?", name, re.I):
            out["index"][name] = _index_view(st.parse_index_page(text, base + "index.htm", spec["offset"]))
        elif re.fullmatch(r"SEG\d+\.html?", name, re.I):
            url = base + name
            out["segments"][name] = {
                "results": st.parse_segment_results(text),
                "starting": st.parse_starting_order(url, text),
            }
        elif re.fullmatch(r"CAT\d+RS\.html?", name, re.I):
            url = base + name
            with mock.patch.object(net, "fetch", return_value=text):
                out["totals"][name] = st.parse_category_results(url)
    return out


def _dump(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=1) + "\n"


class Snapshot(unittest.TestCase):
    def test_families_match_expected(self):
        regen = bool(os.environ.get("STARTY_REGEN"))
        for family in sorted(FAMILIES):
            with self.subTest(family=family):
                got = snapshot(family)
                path = os.path.join(FIX, family, "expected.json")
                if regen:
                    with open(path, "w", encoding="utf-8", newline="\n") as f:
                        f.write(_dump(got))
                    continue
                with open(path, encoding="utf-8") as f:
                    want = json.load(f)
                self.assertEqual(got, want)


if __name__ == "__main__":
    unittest.main()
