#!/usr/bin/env bash
# Общая блокировка публикации gh-pages для update.yml и live.yml.
#   bash tools/pages-lock.sh acquire   — взять (ждёт до LOCK_WAIT секунд, по умолчанию 1200)
#   bash tools/pages-lock.sh release   — отпустить (только свою)
#   REPO_URL — адрес репозитория с токеном.
#
# Замок — ветка pages-lock с одним коммитом «lock <запуск> <время>». Создать ветку, которой нет,
# можно только одному: второй push (другой коммит) не fast-forward и отклоняется сервером — это
# и есть атомарность. Замок старше LOCK_STALE секунд (по умолчанию 900: под замком идут секунды)
# считается брошенным упавшим заданием и снимается. Под замком — короткий шаг: обновить main,
# забрать свежие протоколы, записать, опубликовать. Долгое (полный сбор, сон цикла live) — вне него.
set -euo pipefail
ref=${LOCK_REF:-refs/heads/pages-lock}
stale=${LOCK_STALE:-900}
wait_max=${LOCK_WAIT:-1200}
state=${LOCK_STATE:-${RUNNER_TEMP:-/tmp}/pages-lock.sha}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp/r"
g() { git -C "$tmp/r" -c user.name=lock -c user.email=lock@localhost "$@"; }

case "${1:-}" in
acquire)
  deadline=$(( $(date +%s) + wait_max ))
  while :; do
    now=$(date +%s)
    commit=$(g commit-tree "$(g mktree </dev/null)" -m "lock ${GITHUB_RUN_ID:-local} $now $$-$RANDOM")
    if g push -q "$REPO_URL" "$commit:$ref" 2>/dev/null; then
      echo "$commit" > "$state"
      echo "блокировка публикации взята"
      exit 0
    fi
    if g fetch -q "$REPO_URL" "$ref" 2>/dev/null; then
      held_at=$(g log -1 --format=%s FETCH_HEAD | awk '{print $3}')
      sha=$(g rev-parse FETCH_HEAD)
      if [[ "$held_at" =~ ^[0-9]+$ ]] && [ $(( now - held_at )) -gt "$stale" ]; then
        echo "блокировка брошена ($(( now - held_at )) с), снимаю"
        g push -q "$REPO_URL" --force-with-lease="$ref:$sha" ":$ref" 2>/dev/null || true
        continue
      fi
    fi
    if [ "$now" -ge "$deadline" ]; then
      echo "блокировка публикации занята дольше ${wait_max} с" >&2
      exit 1
    fi
    sleep 10
  done
  ;;
release)
  [ -f "$state" ] || exit 0
  mine=$(cat "$state")
  # снимаем только свой замок: если наш успели счесть брошенным и взять чужой, чужой не трогаем
  g push -q "$REPO_URL" --force-with-lease="$ref:$mine" ":$ref" 2>/dev/null || true
  rm -f "$state"
  echo "блокировка публикации снята"
  ;;
*)
  echo "usage: $0 acquire|release" >&2
  exit 2
  ;;
esac
