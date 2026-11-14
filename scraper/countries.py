"""Страны по кодам ISU по-русски — тот же список, что у приложения (app/lib/countries.dart): один
источник на двоих. Нужен для командного зачёта: там команда — страна. ROC, OAR, FSR, AIN2 — Россия,
AIN1 — Беларусь (как в приложении). Незнакомый код — как есть."""
import os
import re

_DART = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app", "lib", "countries.dart")
SAME = {"ROC": "RUS", "OAR": "RUS", "FSR": "RUS", "ANA": "RUS", "AIN2": "RUS", "AIN1": "BLR"}


def _load():
    try:
        with open(_DART, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return {}
    block = text.split("const countryNames", 1)[-1].split("};", 1)[0]
    return dict(re.findall(r"'([A-Z0-9]{3,4})':\s*'([^']+)'", block))


NAMES = _load()


def ru(code):
    """«USA» → «США», «ROC» → «Россия»; незнакомое — как есть."""
    c = (code or "").upper()
    return NAMES.get(SAME.get(c, c)) or code
