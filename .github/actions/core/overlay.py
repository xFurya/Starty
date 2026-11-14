"""Накладывает исходники закрытого репозитория на рабочую папку витрины.

Витрина — публичный репозиторий: сайт, данные сборщика, сценарии запуска. Кода приложения и сборщика в
ней нет: в начале каждого запуска он подтягивается из закрытого репозитория (action «core») и кладётся
поверх рабочей папки, так что все пути в сценариях прежние. Коммитятся только сайт, данные и состояние
(см. .gitignore витрины), а наложенное — нет.

  python overlay.py <папка с исходниками> <рабочая папка>

Не затирается то, чем владеет витрина: данные сборщика, то, что сборки кладут в site/ (данные, профили,
фото, приложение, веб-версия, календарь) и список выпущенных версий. Лендинг (site/index.html, assets,
pay, iphone) — исходник и берётся из закрытого репозитория.
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
    print(f"наложено файлов: {overlay(sys.argv[1], sys.argv[2])}")
