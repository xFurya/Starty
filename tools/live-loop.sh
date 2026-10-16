#!/usr/bin/env bash
# Цикл живых итогов (live.yml). Пока есть идущие или недавние старты — каждые LIVE_INTERVAL секунд
# (по умолчанию 240) один проход scraper.live; сам заканчивается, когда стартов нет или вышло
# LIVE_MAX секунд (по умолчанию 21000 = 5 ч 50 мин: потолок задания GitHub — 6 ч). Следующий
# запуск по расписанию подхватывает дальше.
#
# Что делает проход (под общей блокировкой tools/pages-lock.sh — короткий шаг, секунды):
#   main → свежие протоколы с gh-pages → scraper.live → коммит в main → публикация gh-pages.
# Долгое (сон между проходами, ожидание начала старта) — вне блокировки, поэтому update.yml
# не ждёт часами и публикации двух заданий не пересекаются.
# Табло: страница — не чаще раза за проход (в проходе кэш), проходы — раз в INTERVAL.
#   REPO_URL — адрес репозитория с токеном; GITHUB_REPOSITORY(_OWNER) — как в Actions.
set -uo pipefail
INTERVAL=${LIVE_INTERVAL:-240}
MAX=${LIVE_MAX:-21000}
started=$(date +%s)
export STARTY_URL="https://${GITHUB_REPOSITORY_OWNER,,}.github.io/${GITHUB_REPOSITORY#*/}/"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

held=0
release() { if [ "$held" = 1 ]; then bash tools/pages-lock.sh release || true; held=0; fi; }
trap release EXIT

fresh_main() { git fetch -q origin main && git reset -q --hard origin/main; }

# контрольная сумма протоколов без status.json: он меняется каждый проход и один публикацию не вызывает
sum() { find site/data/protocols -name '*.json' ! -name status.json -exec sha1sum {} + 2>/dev/null | sort | sha1sum; }

pass() {  # $1 — режим scraper.live ("--hot" или пусто)
  bash tools/pages-lock.sh acquire || { echo "замок занят, пропускаю проход"; return 1; }
  held=1
  fresh_main || { release; return 1; }
  rm -rf site/data/protocols site/.nojekyll
  bash tools/protocols-from-pages.sh || { echo "протоколы с gh-pages не забрались, публиковать нельзя"; release; return 1; }
  local before changed=0
  before=$(sum)
  timeout 420 python3 -m scraper.live $1 || echo "scraper.live завершился с кодом $?"
  git add -A site data
  if ! git diff --cached --quiet || [ "$(sum)" != "$before" ]; then changed=1; fi
  if [ "$changed" = 1 ]; then
    if ! git diff --cached --quiet; then
      git commit -q -m "Итоги на $(TZ=Europe/Moscow date '+%d.%m.%Y %H:%M') МСК"
      for i in 1 2 3; do
        git push -q origin HEAD:main && break
        git pull -q --rebase -X theirs origin main || { git rebase --abort 2>/dev/null; break; }
        sleep 3
      done
    fi
    bash tools/publish-pages.sh || echo "публикация gh-pages не удалась, повторю в следующем проходе"
  else
    echo "изменений нет"
  fi
  release
}

first=1
while :; do
  loop_start=$(date +%s)
  [ $(( loop_start - started )) -ge "$MAX" ] && { echo "время задания вышло"; exit 0; }
  fresh_main || { echo "main недоступен"; sleep 30; continue; }
  read -r what secs <<<"$(python3 -m scraper.live --plan)"
  echo "$(date -u +%H:%M:%S) план: $what ${secs:-}"
  case "$what" in
    hot) pass --hot ;;
    cold) if [ "$first" = 1 ]; then pass ""; fi; exit 0 ;;   # старые неокончательные итоги — раз за запуск
    wait)
      # до начала старта: ждём, но не дольше, чем хватит задания, и не больше 5 минут за раз
      if [ $(( loop_start - started + secs )) -ge "$MAX" ]; then echo "старт позже конца задания"; exit 0; fi
      sleep $(( secs < 300 ? secs : 300 )); first=0; continue ;;
    *) exit 0 ;;
  esac
  first=0
  spent=$(( $(date +%s) - loop_start ))
  [ "$spent" -lt "$INTERVAL" ] && sleep $(( INTERVAL - spent ))
done
