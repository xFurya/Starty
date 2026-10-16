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
import unicodedata

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
    s = unicodedata.normalize("NFKD", s.lower().replace("ł", "l").replace("đ", "d"))
    s = re.sub(r"[^a-z]", "", s)  # «Jakušina» → «jakusina»: знаки над буквами отбрасываем, а не буквы
    for a, b in (("x", "ks"), ("shch", "sch"), ("kh", "h"), ("ye", "e"), ("yo", "e"),
                 ("iy", "i"), ("yi", "i"), ("y", "i"), ("j", "i"), ("w", "v"), ("ph", "f"),
                 ("ie", "e"), ("tch", "ch"), ("ts", "c"), ("tc", "c"), ("tz", "c")):
        s = s.replace(a, b)
    s = re.sub(r"(.)\1+", r"\1", s)  # двойные буквы
    return s


# Вторая, грубая свёртка — только чтобы узнать одного человека в разных написаниях
# (Rubtsova / Rubcova / Rubtcova, Skoptsova / Skoptcova, Beklemisheva / Beklemishcheva).
_FOLD = (("shch", "s"), ("sch", "s"), ("shh", "s"), ("sh", "s"), ("zh", "z"), ("kh", "h"), ("ch", "c"),
         ("ts", "c"), ("tc", "c"), ("tz", "c"), ("ya", "a"), ("ia", "a"), ("ja", "a"), ("yu", "u"),
         ("iu", "u"), ("ju", "u"), ("ks", "x"), ("ie", "e"), ("ee", "e"))


def fold(s):
    s = norm_lat(s)
    for a, b in _FOLD:
        s = s.replace(a, b)
    return re.sub(r"(.)\1+", r"\1", s)


def _parts(name):
    """(фамилия, имя) в грубой свёртке; None, если не разобрать."""
    name = name.replace("ё", "е").replace("Ё", "Е")
    if is_cyr(name):
        w = name.split()
        if len(w) < 2:
            return None
        fam, giv = w[-1], " ".join(w[:-1])
        return fold(ru_to_lat(fam)), fold(ru_to_lat(giv))
    if "," in name:  # «Павлова, Наталья Евгеньевна» бывает и латиницей: «Kulikova, Svetlana»
        fam, _, giv = name.partition(",")
        giv = giv.split()[0] if giv.split() else ""
    else:
        giv, fam = split_given_family(name)
        if not fam:
            w = name.split()
            if len(w) < 2:
                return None
            giv, fam = " ".join(w[:-1]), w[-1]
    if not fam or not giv:
        return None
    return fold(fam), fold(giv)


def near(a, b):
    """Похоже ли, что это один человек: одно и то же имя и фамилия с точностью до одной буквы
    (Чернобавская / Чернявская, Олова / Орлова — разные люди). Для имён из надёжных источников."""
    pa, pb = _parts(a), _parts(b)
    if not pa or not pb:
        return False
    (fa, ga), (fb, gb) = pa, pb
    if ga[:1] != gb[:1] or fa[:1] != fb[:1]:
        return False
    if min(len(fa), len(fb)) < 5 or _lev(ga, gb) > 1 or _lev(fa, fb) > 1:
        return False
    # Иванов / Иванова: разный пол — разные люди
    return not (fa != fb and {fa[-1:], fb[-1:]} == {"a", "v"} or fa[:-1] == fb or fb[:-1] == fa)


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


def _latin_names():
    """Белорусы и другие, кого нет в российских списках: латиница протокола → по-русски (config.json → latin_names)."""
    try:
        with open(os.path.join(os.path.dirname(__file__), "config.json"), encoding="utf-8") as f:
            return json.load(f).get("latin_names") or {}
    except (OSError, ValueError):
        return {}


class Names:
    def __init__(self, path=None, aliases=None):
        self.path = path
        self.ru = {}  # ключ → «Имя Фамилия»
        self.aliases = aliases or {}
        self.latin = {}  # ключ из латиницы → «Имя Фамилия»
        for lat, ru in _latin_names().items():
            given, _, family = lat.rpartition(" ")
            self.latin[(norm_lat(family), norm_lat(given))] = ru
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
        hit = self.latin.get((kf, kg)) or self.ru.get((kf, kg))
        if not hit:
            cands = [v for (f, g), v in self.ru.items() if f == kf and g[:3] == kg[:3]]
            if len(cands) == 1:
                hit = cands[0]
        if not hit and len(kf) >= 5:
            # иностранные фамилии наших (Cirisano ↔ Чиризано): имя совпадает точно,
            # фамилия — с точностью до двух букв, и кандидат ровно один
            # (первая буква та же и короткие фамилии — на одну букву: Orlova ≠ Фролова)
            cands = [v for (f, g), v in self.ru.items()
                     if g == kg and f[:1] == kf[:1] and _lev(f, kf) <= (2 if len(kf) >= 8 else 1)
                     and f + "a" != kf and kf + "a" != f]  # Иванов ≠ Иванова: другой пол — другой человек
            if len(cands) == 1:
                hit = cands[0]
        if hit:
            return self._alias(hit)
        return pretty_latin(name)

    def known_latin(self, name):
        """Латинское «Имя Фамилия» (в любом регистре), которое мы знаем по-русски."""
        if is_cyr(name) or " / " in name:
            return False
        given, _, family = name.strip().rpartition(" ")
        k = (norm_lat(family), norm_lat(given))
        return k in self.latin or k in self.ru

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
