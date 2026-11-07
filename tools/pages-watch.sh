#!/usr/bin/env bash
# Сторож выкладки сайта. GitHub Pages иногда не доводит публикацию до сайта: шаг «syncing_files»
# упирается в свой 10-минутный предел, выкладка отменяется, и сайт — а с ним «Обновление» в
# приложении — остаётся прежним до следующей публикации, которая утром бывает через несколько часов.
#
# Каждая публикация кладёт на gh-pages метку pub.txt (tools/publish-pages.sh). Если голове gh-pages
# больше WATCH_AFTER секунд (по умолчанию 1200: выкладка дольше 10 минут не живёт), а сайт отдаёт
# другую метку — та же голова публикуется ещё раз, новым коммитом с тем же деревом, и Pages
# выкладывает её заново. На сервер уходит только коммит: дерево и файлы там уже есть.
# Проверка — запрос к сайту и клон gh-pages без содержимого файлов (сотни КБ).
#   REPO_URL — адрес репозитория с токеном; GITHUB_REPOSITORY(_OWNER) — как в Actions;
#   SITE_URL — адрес сайта (по умолчанию https://<владелец>.github.io/<репозиторий>/).
set -euo pipefail
after=${WATCH_AFTER:-1200}
site=${SITE_URL:-https://${GITHUB_REPOSITORY_OWNER,,}.github.io/${GITHUB_REPOSITORY#*/}/}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! git clone -q --depth 1 --filter=blob:none --no-checkout --branch gh-pages "$REPO_URL" "$tmp/p" 2>/dev/null; then
  echo "gh-pages не прочитать — проверю в следующий раз"
  exit 0
fi
g() { git -C "$tmp/p" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" "$@"; }
sha=$(g rev-parse HEAD)
age=$(( $(date +%s) - $(g log -1 --format=%ct HEAD) ))
if [ "$age" -lt "$after" ]; then
  echo "публикации $((age / 60)) мин — выкладка ещё может идти"
  exit 0
fi
if ! want=$(g show HEAD:pub.txt 2>/dev/null); then
  echo "на gh-pages нет метки — публикация старого образца, сверять не с чем"
  exit 0
fi
# ?t= — мимо кэша CDN: сайт отдаёт файлы с кэшем на 10 минут
got=$(curl -fsS --max-time 20 "${site}pub.txt?t=$(date +%s)" 2>/dev/null || true)
if [ "$got" = "$want" ]; then
  echo "сайт выложен (метка $want)"
  exit 0
fi

echo "на gh-pages метка $want уже $((age / 60)) мин, сайт отдаёт «${got:-ничего}» — выкладка пропала, публикую заново"
msg=$(g log -1 --format=%s HEAD)
msg=${msg% (повтор выкладки)}
new=$(g commit-tree "HEAD^{tree}" -m "$msg (повтор выкладки)")
# только поверх той головы, что сверяли: если тем временем опубликовали новое — его выкладка и так идёт
if g push -q --force-with-lease="gh-pages:$sha" "$REPO_URL" "$new:refs/heads/gh-pages"; then
  echo "gh-pages опубликован заново: $new"
else
  echo "gh-pages успели сменить — новая выкладка уже идёт"
fi
