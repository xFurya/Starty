#!/usr/bin/env bash
# Отправка коммита выпуска (app-android.yml, app-ios.yml). Оба задания правят site/app/version.json,
# каждое — только свою секцию («android» или «ios»); одновременный выпуск давал конфликт, и коммит терялся.
# При конфликте берём файл как есть на сервере, заново накладываем свою секцию и продолжаем.
#   release-push.sh android|ios
set -uo pipefail
PLATFORM=${1:?платформа}
for i in 1 2 3 4; do
  if git pull -q --rebase; then
    git push -q && exit 0
  else
    if git diff --name-only --diff-filter=U | grep -qvx 'site/app/version.json'; then
      echo "конфликт не только в version.json" >&2
      git rebase --abort 2>/dev/null || true
    else
      # во время rebase «ours» — то, что уже на сервере, REBASE_HEAD — наш коммит
      git checkout --ours site/app/version.json
      python3 - "$PLATFORM" <<'PY'
import json, subprocess, sys
p = sys.argv[1]
mine = json.loads(subprocess.check_output(["git", "show", "REBASE_HEAD:site/app/version.json"]))
cur = json.load(open("site/app/version.json"))
cur[p] = mine[p]
json.dump(cur, open("site/app/version.json", "w"), ensure_ascii=False, indent=1)
PY
      git add site/app/version.json
      if GIT_EDITOR=true git rebase --continue; then
        git push -q && exit 0
      fi
      git rebase --abort 2>/dev/null || true
    fi
  fi
  sleep 5
done
echo "коммит выпуска не отправлен (конфликт или сеть)" >&2
exit 1
