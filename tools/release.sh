#!/usr/bin/env bash
# Выпуск новой версии приложения «Фигурное катание» — как у Дневника: телефон
# найдёт её на сайте сам (site/app/latest.json) и поставит, когда приложение свернут.
#
#   bash tools/release.sh 1.0.3 "Исправлена ошибка уведомления."
#
# Описание — одна короткая строка общими словами: его читают в приложении.
# Номер сборки выдаётся один раз (tools/released.tsv): телефон ставит по номеру,
# второй выпуск под тем же номером не увидит никогда. Ключ подписи — вне этого
# репозитория, путь в app/android/key.properties.
#
# После: закоммитить и запушить main. iPhone-сборку соберёт .github/workflows/app-ios.yml
# и сам обновит site/app/sidestore.json.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=${1:?"версия, например 1.0.3"}
NOTES=${2:?"описание обновления: одна короткая строка"}
CERT=84f451ebac960ae69f8bf06949be9ad8abe86571cc475a36249790851fb0e7d1

fail() { echo "$*" >&2; exit 1; }
[[ $VER =~ ^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] || fail "версия — три числа: 1.0.3"
[[ $NOTES != *$'\n'* && ${#NOTES} -le 120 ]] || fail "описание — одна строка до 120 знаков"
test -f app/android/key.properties || fail "нет app/android/key.properties — без ключа подписи обновление не встанет"
cut -f2 tools/released.tsv | grep -qx "$VER" && fail "версия $VER уже выпускалась"
LAST=$(tail -n1 tools/released.tsv | cut -f1)
BUILD=$((LAST + 1))

. /opt/sdk/env.sh 2>/dev/null || true
sed -i "s/^version: .*/version: $VER+$BUILD/" app/pubspec.yaml
(cd app && flutter build apk --release --target-platform android-arm64 \
  --dart-define=BUILD="$BUILD" --dart-define=VERSION="$VER")
APK=app/build/app/outputs/flutter-apk/app-release.apk

# подпись прежняя — иначе обновление не встанет поверх
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp "$APK" "$TMP/a.apk"
SIGNER=$(ls -d "${ANDROID_HOME:-/opt/android-sdk}"/build-tools/*/ | sort -V | tail -n1)apksigner
"$SIGNER" verify --print-certs "$TMP/a.apk" | grep -q "SHA-256 digest: $CERT" || fail "сборка подписана не тем ключом"

rm -f site/app/starty-*.apk
cp "$APK" site/app/Starty.apk
cp "$APK" "site/app/starty-$VER.apk"
python3 - "$VER" "$BUILD" "$NOTES" <<'EOF'
import datetime, hashlib, json, os, sys
ver, build, notes = sys.argv[1], int(sys.argv[2]), sys.argv[3]
apk = f"site/app/starty-{ver}.apk"
raw = open(apk, "rb").read()
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
latest = {"version": ver, "code": build, "notes": notes, "at": now,
          "android": {"file": os.path.basename(apk), "size": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}}
json.dump(latest, open("site/app/latest.json", "w"), ensure_ascii=False, indent=1)
# для версий до 1.0.2 — у них только строка «Новая версия» со ссылкой на файл
v = json.load(open("site/app/version.json"))
v["android"].update(version=ver, build=build, note=notes)
v["ios"].update(version=ver, build=build, note=notes)
json.dump(v, open("site/app/version.json", "w"), ensure_ascii=False, indent=1)
with open("tools/released.tsv", "a") as f:
    f.write(f"{build}\t{ver}\t{now[:10]}\t{latest['android']['sha256']}\t{notes}\n")
print(f"выпуск {ver} ({build}): {len(raw)} байт, sha256 {latest['android']['sha256'][:12]}…")
EOF
echo "Готово. Осталось закоммитить и запушить main."
