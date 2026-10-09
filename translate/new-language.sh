#!/usr/bin/env bash
# Start a new translation:   bash translate/new-language.sh pt_BR
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
lang="${1:-}"
[[ -n "$lang" ]] || { echo "Usage: $0 <language code, e.g. es, fr, pt_BR>" >&2; exit 2; }
[[ -f "po/$lang.po" ]] && { echo "po/$lang.po already exists." >&2; exit 1; }
command -v msginit >/dev/null || { echo "msginit not found (install gettext)." >&2; exit 1; }

[[ -f po/template.pot ]] || bash translate/merge.sh
msginit --no-translator --locale="$lang" --input=po/template.pot --output-file="po/$lang.po"
echo "Created po/$lang.po – translate it, then run: bash translate/build.sh"
