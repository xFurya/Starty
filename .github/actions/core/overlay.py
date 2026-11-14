"""Накладывает исходники на рабочую папку.

  python overlay.py <папка с исходниками> <рабочая папка>

Не затирается то, что принадлежит рабочей папке (KEEP): данные, результаты сборок, список версий.
"""
import os
import shutil
import sys

KEEP = (".git", ".github", ".gitignore", "README.md", "data", "site/data", "site/p", "site/h", "site/photos", "site/e", "site/app",
        "site/web", "site/calendar.ics", "tools/released.tsv")


def keep(rel):
    rel = rel.replace(os.sep, "/").strip("/")
    return any(rel == k or rel.startswith(k + "/") for k in KEEP)


def overlay(core, dest):
    """→ сколько файлов наложено."""
    n = 0
    for root, dirs, files in os.walk(core):
        r = os.path.relpath(root, core).replace(os.sep, "/")
        r = "" if r == "." else r
        dirs[:] = [d for d in dirs if not keep(f"{r}/{d}")]
        for f in files:
            rel = f"{r}/{f}".strip("/")
            if keep(rel):
                continue
            dst = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
            shutil.copy2(os.path.join(root, f), dst)
            n += 1
    return n


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    # только ASCII: консоль Windows (cp1252) не печатает кириллицу и роняла шаг уже после копирования
    print(f"overlaid files: {overlay(sys.argv[1], sys.argv[2])}")
