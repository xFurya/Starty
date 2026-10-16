#!/usr/bin/env bash
# Прежние файлы протоколов с gh-pages → site/data/protocols (до сборки).
# Протоколы в main не коммитятся, а публикация gh-pages каждый раз пересоздаёт сайт из site/:
# без этого шага прошлые файлы турниров пропали бы с сайта. Если gh-pages есть, но забрать
# не удалось, — ошибка: публиковать дальше нельзя, иначе прежние протоколы сотрутся.
#   REPO_URL — адрес репозитория с токеном (как у шага публикации).
#   DEST — куда класть (по умолчанию site/data/protocols).
set -euo pipefail
dest=${DEST:-site/data/protocols}
mkdir -p "$dest"
heads=$(git ls-remote --heads "$REPO_URL")
if ! grep -q 'refs/heads/gh-pages' <<<"$heads"; then
  echo "gh-pages ещё нет: прежних протоколов нет"
  exit 0
fi
tmp=$(mktemp -d)
git clone -q --depth 1 --filter=blob:none --sparse --branch gh-pages "$REPO_URL" "$tmp/pages"
git -C "$tmp/pages" sparse-checkout set data/protocols
if [ -d "$tmp/pages/data/protocols" ]; then
  cp "$tmp/pages/data/protocols/"*.json "$dest/" 2>/dev/null || true
fi
echo "протоколов с gh-pages: $(find "$dest" -name '*.json' ! -name status.json | wc -l)"
rm -rf "$tmp"
