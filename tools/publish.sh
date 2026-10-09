#!/usr/bin/env bash
# Первая выкладка в отдельный публичный репозиторий:
#   bash tools/publish.sh https://github.com/<владелец>/starty.git
# Кладёт содержимое этой папки в main и папку site/ в gh-pages (её показывает
# GitHub Pages). Дальше всё обновляет .github/workflows/update.yml сам.
set -euo pipefail
REMOTE="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp -a "$HERE/." "$WORK/"
rm -rf "$WORK/.git" "$WORK"/scraper/__pycache__
cd "$WORK"
git init -q -b main
git add -A
git commit -q -m "Календарь стартов по фигурному катанию"
git push -q -f "$REMOTE" main

cd site
touch .nojekyll
git init -q -b gh-pages
git add -A
git commit -q -m "Сайт"
git push -q -f "$REMOTE" gh-pages
echo "Готово: main и gh-pages в $REMOTE"
