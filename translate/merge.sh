#!/usr/bin/env bash
# Extract every translatable string (QML/JS i18n calls + metadata.json Name and
# Description) into po/template.pot and merge it into each po/<lang>.po.
# Run after changing any user-visible string.
#   bash translate/merge.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
DOMAIN="plasma_applet_org.kde.cppserver"
POT="po/template.pot"

for tool in xgettext msgmerge python3; do
    command -v "$tool" >/dev/null || { echo "Missing '$tool' (install gettext / python3)." >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# metadata.json is not code: expose its strings as i18n() calls for xgettext.
python3 - > "$tmp/metadata.js" <<'PY'
import json
kp = json.load(open("metadata.json"))["KPlugin"]
for key in ("Name", "Description"):
    if kp.get(key):
        print("// metadata.json: KPlugin.%s" % key)
        print("i18n(%s);" % json.dumps(kp[key], ensure_ascii=False))
PY

find contents -type f \( -name '*.qml' -o -name '*.js' \) | LC_ALL=C sort > "$tmp/files"
echo "$tmp/metadata.js" >> "$tmp/files"

mkdir -p po
xgettext \
    --from-code=UTF-8 --language=JavaScript \
    --keyword=i18n:1 --keyword=i18nc:1c,2 --keyword=i18np:1,2 --keyword=i18ncp:1c,2,3 \
    --keyword=i18nd:2 --keyword=i18ndc:2c,3 --keyword=i18ndp:2,3 --keyword=i18ndcp:2c,3,4 \
    --add-comments=i18n --sort-by-file \
    --package-name="$DOMAIN" --msgid-bugs-address="https://github.com/iguruspain" \
    -o "$POT" -f "$tmp/files"

# Point the temporary metadata file at something readable in the references.
sed -i "s#$tmp/metadata.js#metadata.json#" "$POT"

echo "Wrote $POT ($(grep -c '^msgid ' "$POT") entries incl. header)"

shopt -s nullglob
for po in po/*.po; do
    msgmerge --update --backup=none --quiet "$po" "$POT"
    msgattrib --no-obsolete --output-file="$po" "$po"   # drop strings no longer in the code
    echo "Merged $(basename "$po"):  $(msgfmt --statistics -o /dev/null "$po" 2>&1)"
done
