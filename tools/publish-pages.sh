#!/usr/bin/env bash
# site/ → gh-pages одним коммитом (история не растёт). Вызывать под блокировкой pages-lock.sh.
# Запись сравнивающая (--force-with-lease на ту голову, что видели прямо перед ней): сбой
# сети или публикация мимо замка не ломают push, он повторяется на свежей голове.
#   REPO_URL — адрес репозитория с токеном.
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_DIR="$tmp/g" GIT_WORK_TREE="$PWD/site"
touch site/.nojekyll
git init -q -b gh-pages
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -A
git commit -q -m "Сайт: $(TZ=Europe/Moscow date '+%d.%m.%Y %H:%M') МСК"
for i in 1 2 3; do
  head=$(git ls-remote --heads "$REPO_URL" gh-pages | cut -f1)
  if git push -q --force-with-lease="gh-pages:$head" "$REPO_URL" gh-pages; then
    echo "Опубликовано: https://${GITHUB_REPOSITORY_OWNER:-x}.github.io/${GITHUB_REPOSITORY#*/}/"
    exit 0
  fi
  echo "gh-pages изменили во время публикации, повтор $i"
  sleep 5
done
echo "не удалось опубликовать gh-pages" >&2
exit 1
