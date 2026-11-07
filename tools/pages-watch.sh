#!/usr/bin/env bash
# Сторож выкладки сайта. GitHub Pages иногда не доводит публикацию до сайта: шаг «syncing_files»
# упирается в свой 10-минутный предел, выкладка отменяется, и сайт — а с ним «Обновление» в
# приложении — остаётся прежним до следующей публикации, которая утром бывает через несколько часов.
#
# Каждая публикация кладёт на gh-pages метку pub.txt (tools/publish-pages.sh). Если голове gh-pages
# больше WATCH_AFTER секунд (по умолчанию 1200), а сайт отдаёт другую метку — та же голова
# публикуется ещё раз, новым коммитом с тем же деревом, и Pages выкладывает её заново. На сервер
# уходит только коммит: дерево и файлы там уже есть.
#
# Два режима:
#   • разовая проверка (WATCH_WAIT=0, по умолчанию) — live.yml по расписанию;
#   • ожидание (WATCH_WAIT=<секунд>) — сразу после публикации (update.yml): каждые 30 секунд
#     сверяет сайт, пока он не отдаст метку свежей головы; не отдал за WATCH_AFTER — публикует
#     заново и ждёт уже её. Опубликовал тем временем кто-то другой — ждёт его публикацию.
# Голова gh-pages — git ls-remote; клон без содержимого файлов (сотни КБ) — только когда она сменилась.
#   REPO_URL — адрес репозитория с токеном; GITHUB_REPOSITORY(_OWNER) — как в Actions;
#   SITE_URL — адрес сайта (по умолчанию https://<владелец>.github.io/<репозиторий>/).
set -euo pipefail
after=${WATCH_AFTER:-1200}
wait_max=${WATCH_WAIT:-0}
site=${SITE_URL:-https://${GITHUB_REPOSITORY_OWNER,,}.github.io/${GITHUB_REPOSITORY#*/}/}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
g() { git -C "$tmp/p" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" "$@"; }
seen="" want="" when=0

# 0 — ждать больше нечего (сайт выложен или сверять не с чем), 1 — ещё ждём
check() {
  local head got age msg new
  head=$(git ls-remote --heads "$REPO_URL" gh-pages 2>/dev/null | cut -f1) || head=""
  if [ -z "$head" ]; then
    echo "gh-pages не прочитать"
    return 1
  fi
  if [ "$head" != "$seen" ]; then
    rm -rf "$tmp/p"
    git clone -q --depth 1 --filter=blob:none --no-checkout --branch gh-pages "$REPO_URL" "$tmp/p" 2>/dev/null ||
      { echo "gh-pages не скачать"; return 1; }
    seen=$(g rev-parse HEAD)
    when=$(g log -1 --format=%ct HEAD)
    want=$(g show HEAD:pub.txt 2>/dev/null) || want=""
  fi
  if [ -z "$want" ]; then
    echo "на gh-pages нет метки — публикация старого образца, сверять не с чем"
    return 0
  fi
  # ?t= — мимо кэша CDN: сайт отдаёт файлы с кэшем на 10 минут
  got=$(curl -fsS --max-time 20 "${site}pub.txt?t=$(date +%s)" 2>/dev/null || true)
  if [ "$got" = "$want" ]; then
    echo "сайт выложен (метка $want)"
    return 0
  fi
  age=$(( $(date +%s) - when ))
  if [ "$age" -lt "$after" ]; then
    echo "публикации $((age / 60)) мин, сайт ещё прежний — выкладка может идти"
    return 1
  fi
  echo "на gh-pages метка $want уже $((age / 60)) мин, сайт отдаёт «${got:-ничего}» — выкладка пропала, публикую заново"
  msg=$(g log -1 --format=%s HEAD)
  msg=${msg% (повтор выкладки)}
  new=$(g commit-tree "HEAD^{tree}" -m "$msg (повтор выкладки)")
  # только поверх той головы, что сверяли: если тем временем опубликовали новое — его выкладка и так идёт
  if g push -q --force-with-lease="gh-pages:$seen" "$REPO_URL" "$new:refs/heads/gh-pages"; then
    echo "gh-pages опубликован заново: $new"
  else
    echo "gh-pages успели сменить — новая выкладка уже идёт"
  fi
  return 1
}

deadline=$(( $(date +%s) + wait_max ))
until check; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    [ "$wait_max" = 0 ] || echo "за $((wait_max / 60)) мин сайт метку так и не отдал — дальше проверит live.yml"
    exit 0
  fi
  sleep "${WATCH_STEP:-30}"
done
