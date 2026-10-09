"""Имена спортсменов.

Международные протоколы пишут наших латиницей («Viktoriia STRELTSOVA»), а
показывать нужно по-русски. Обратная транслитерация угадывает мягкие знаки и
«э/е» наугад, поэтому кириллица берётся только из словаря: сборная ФФККР и все
российские стартовые листы, которые сборщик видел (словарь копится между
запусками в data/names.json). Не нашлось в словаре — показываем как в протоколе,
латиницей, а не правдоподобную выдумку.
"""
import json
import os
import re

ICAO = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh",
    "з": "z", "и": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
    "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
    "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "ie", "ы": "y", "ь": "", "э": "e",
    "ю": "iu", "я": "ia",
}


def ru_to_lat(s):
    return "".join(ICAO.get(ch, ch) for ch in s.lower())


def norm_lat(s):
    """Свести разные латинские написания к одному ключу."""
    s = s.lower()
    s = re.sub(r"[^a-z]", "", s)
    for a, b in (("x", "ks"), ("shch", "sch"), ("kh", "h"), ("ye", "e"), ("yo", "e"),
                 ("iy", "i"), ("yi", "i"), ("y", "i"), ("j", "i"), ("w", "v"), ("ph", "f"),
                 ("ie", "e")):
        s = s.replace(a, b)
    s = re.sub(r"(.)\1+", r"\1", s)  # двойные буквы
    return s


def is_cyr(s):
    return bool(re.search(r"[А-Яа-яЁё]", s))


def pretty_ru(name):
    """«Екатерина КОРЧАЖНИКОВА» → «Екатерина Корчажникова»."""
    def cap(w):
        return "-".join(p[:1].upper() + p[1:].lower() for p in w.split("-"))
    return " ".join(cap(w) if w.isupper() and len(w) > 1 else w for w in name.split())


def split_given_family(name):
    """Латинское имя протокола: фамилия — слова капсом; инициалы («Anna M.») отбрасываем."""
    words = name.split()
    fam = [w for w in words if w.isupper() and len(w) > 1 and not w.endswith(".")]
    giv = [w for w in words if not (w.isupper() and len(w) > 1) and not re.fullmatch(r"[A-Z]\.", w)]
    return " ".join(giv), " ".join(fam)


def _lev(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


class Names:
    def __init__(self, path=None, aliases=None):
        self.path = path
        self.ru = {}  # ключ → «Имя Фамилия»
        self.aliases = aliases or {}
        if path and os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                for full in json.load(f):
                    self.add(full)

    def add(self, full_ru):
        """Добавить русское имя «Имя Фамилия» (порядок любой, фамилия может быть капсом)."""
        full_ru = pretty_ru(re.sub(r"\s+", " ", full_ru.replace("\xa0", " ")).strip())
        parts = full_ru.split()
        if len(parts) < 2 or not is_cyr(full_ru):
            return
        given, family = " ".join(parts[:-1]), parts[-1]
        self.ru[(norm_lat(ru_to_lat(family)), norm_lat(ru_to_lat(given)))] = full_ru

    def add_fsr(self, surname, given):
        self.add(f"{given} {surname}")

    def save(self):
        if not self.path:
            return
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(sorted(set(self.ru.values())), f, ensure_ascii=False, indent=0)

    def to_ru(self, name):
        """Одиночник или пара «A / B» → по-русски, если знаем, иначе как есть."""
        if " / " in name:
            return " / ".join(self.to_ru(p.strip()) for p in name.split(" / "))
        if is_cyr(name):
            return self._alias(pretty_ru(name))
        given, family = split_given_family(name)
        kf, kg = norm_lat(family), norm_lat(given)
        hit = self.ru.get((kf, kg))
        if not hit:
            cands = [v for (f, g), v in self.ru.items() if f == kf and g[:3] == kg[:3]]
            if len(cands) == 1:
                hit = cands[0]
        if not hit and len(kf) >= 5:
            # иностранные фамилии наших (Cirisano ↔ Чиризано): имя совпадает точно,
            # фамилия — с точностью до двух букв, и кандидат ровно один
            cands = [v for (f, g), v in self.ru.items() if g == kg and _lev(f, kf) <= 2]
            if len(cands) == 1:
                hit = cands[0]
        if hit:
            return self._alias(hit)
        return pretty_latin(name)

    def _alias(self, s):
        return self.aliases.get(s, s)


def pretty_latin(name):
    if " / " in name:
        return " / ".join(pretty_latin(p) for p in name.split(" / "))
    return " ".join(w.capitalize() if w.isupper() and len(w) > 1 else w for w in name.split())


def key(name):
    """Ключ для сравнения имён из разных источников (кириллица/латиница, ё/е, регистр)."""
    if " / " in name:
        return " / ".join(key(p) for p in name.split(" / "))
    s = name.replace("ё", "е").replace("Ё", "Е")
    lat = ru_to_lat(s) if is_cyr(s) else s
    words = sorted(norm_lat(w) for w in lat.split() if norm_lat(w))
    return " ".join(words)
