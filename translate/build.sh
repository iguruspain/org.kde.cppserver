#!/usr/bin/env bash
# Compile po/<lang>.po into contents/locale/<lang>/LC_MESSAGES/<domain>.mo (what
# Plasma loads for locally installed widgets) and write the translated
# Name[<lang>] / Description[<lang>] into metadata.json.
# install.sh runs this automatically.
#   bash translate/build.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
DOMAIN="plasma_applet_org.kde.cppserver"

command -v msgfmt >/dev/null || { echo "msgfmt not found (install gettext): skipping translations." >&2; exit 0; }

rm -rf contents/locale
shopt -s nullglob
langs=()
for po in po/*.po; do
    lang="$(basename "$po" .po)"
    dir="contents/locale/$lang/LC_MESSAGES"
    mkdir -p "$dir"
    msgfmt --check --output-file="$dir/$DOMAIN.mo" "$po"
    langs+=("$lang")
    echo "Built $lang"
done

python3 - "${langs[@]}" <<'PY'
import gettext, json, re, sys
domain = "plasma_applet_org.kde.cppserver"
langs = sys.argv[1:]
with open("metadata.json", encoding="utf-8") as f:
    meta = json.load(f)
kp = meta["KPlugin"]
# drop previously generated translations, then regenerate
for key in list(kp):
    if re.match(r"^(Name|Description)\[.+\]$", key):
        del kp[key]
for lang in langs:
    t = gettext.GNUTranslations(open(f"contents/locale/{lang}/LC_MESSAGES/{domain}.mo", "rb"))
    for key in ("Name", "Description"):
        src = kp.get(key)
        if not src:
            continue
        tr = t.gettext(src)
        if tr and tr != src:
            kp[f"{key}[{lang}]"] = tr
with open("metadata.json", "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=4, ensure_ascii=False)
    f.write("\n")
PY
echo "metadata.json updated for: ${langs[*]:-(no languages)}"
