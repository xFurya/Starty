#!/usr/bin/env bash
# Проверки подписки: схема на чистом Postgres (нужен локальный сервер, пользователь postgres) и функции
# сервера на Node 22 (без сети: платёжные сервисы подменены).
#   bash tools/billing/test/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
db="billing_test_$$"

if command -v psql >/dev/null; then
  as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -c "$*"; else eval "$*"; fi; }
  as_pg "createdb $db"
  trap 'as_pg "dropdb --if-exists $db"' EXIT
  as_pg "psql -X -q -d $db -f '$here/schema_test.sql'"
else
  echo 'psql нет — схема не проверена' >&2
fi

node --experimental-strip-types --no-warnings --test "$here"/*.test.ts
