#!/usr/bin/env bash
# Цикл живых итогов (live.yml). Пока есть идущие или недавние старты — каждые LIVE_INTERVAL секунд
# (по умолчанию 240) один проход scraper.live. Раз в LIVE_COLD_EVERY секунд (900) вместо горячего
# прохода идёт полный — с неокончательными итогами уже прошедших сегментов; когда горячих нет, а
# неокончательные есть, — раз в LIVE_COLD_REPEAT (3600).
#
# Сторож. Расписание cron у GitHub приходит с опозданием на часы или не приходит, поэтому, пока до
# какого-нибудь старта меньше суток (scraper.live --plan), цикл не выходит, а ждёт; полный сбор
# (update.yml) запускает сам, когда у близкого старта нет стартового листа или сбора давно не было
# (scraper.live --due), не чаще раза в LIVE_REFULL секунд (3600). Через LIVE_MAX секунд (21000 =
# 5 ч 50 мин: потолок задания GitHub — 6 ч) задание кончается и, если старты впереди, запускает
# следующее: оно ждёт в очереди группы live и начинается сразу после этого.
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
COLD_EVERY=${LIVE_COLD_EVERY:-900}
COLD_REPEAT=${LIVE_COLD_REPEAT:-3600}
REFULL=${LIVE_REFULL:-3600}
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

# полный сбор, если пора и он не идёт: стартовые листы близких стартов, всё, что cron не принёс
last_dispatch=0
due_check() {
  local now why busy
  now=$(date +%s)
  [ $(( now - last_dispatch )) -lt "$REFULL" ] && return 0
  why=$(python3 -m scraper.live --due) || return 0
  busy=$(gh run list --workflow update.yml --json status \
    --jq '[.[] | select(.status != "completed")] | length' 2>/dev/null) || { echo "список запусков недоступен"; return 0; }
  if [ "${busy:-0}" = 0 ]; then
    echo "полный сбор: $why"
    gh workflow run update.yml --ref main && last_dispatch=$now
  fi
}

# задание кончается, а старты впереди: следующее ждёт в очереди группы live и подхватывает без разрыва
again() {
  local what
  read -r what _ <<<"$(python3 -m scraper.live --plan)"
  if [ "$what" != none ]; then
    gh workflow run live.yml --ref main && echo "следующее задание запущено"
  fi
}

first=1
last_full=0
while :; do
  loop_start=$(date +%s)
  left=$(( MAX - (loop_start - started) ))
  [ "$left" -le 0 ] && { echo "время задания вышло"; again; exit 0; }
  fresh_main || { echo "main недоступен"; sleep 30; continue; }
  read -r what secs <<<"$(python3 -m scraper.live --plan)"
  echo "$(date -u +%H:%M:%S) план: $what ${secs:-}"
  [ "$what" = none ] && exit 0
  due_check
  case "$what" in
    hot)
      # идущие старты — каждый проход, а старые неокончательные итоги (утренние сегменты, до
      # которых задание не дотянулось) — полным проходом при входе и раз в COLD_EVERY секунд:
      # иначе, пока идёт хоть один старт, они не обновлялись бы вовсе
      if [ "$first" = 1 ] || [ $(( loop_start - last_full )) -ge "$COLD_EVERY" ]; then
        pass ""; last_full=$(date +%s)
      else
        pass --hot
      fi ;;
    cold)
      # горячих нет: старые неокончательные — при входе и раз в COLD_REPEAT, между ними ждём
      if [ "$first" = 1 ] || [ $(( loop_start - last_full )) -ge "$COLD_REPEAT" ]; then
        pass ""; last_full=$(date +%s)
      fi
      first=0; sleep $(( left < 300 ? left : 300 )); continue ;;
    wait)
      # до начала старта: не больше 5 минут за раз и не дольше, чем осталось заданию
      s=$(( secs < 300 ? secs : 300 ))
      sleep $(( s < left ? s : left )); first=0; continue ;;
  esac
  first=0
  spent=$(( $(date +%s) - loop_start ))
  [ "$spent" -lt "$INTERVAL" ] && sleep $(( INTERVAL - spent ))
done
