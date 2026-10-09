#!/usr/bin/env bash
# Build a .plasmoid package (a zip with metadata.json and contents/ at its root)
# that can be installed from "Add Widgets > Get New Widgets > Install Widget
# From Local File…" or with: kpackagetool6 -t Plasma/Applet -i org.kde.cppserver.plasmoid
#   bash make-plasmoid.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
command -v zip >/dev/null || { echo "zip not found." >&2; exit 1; }

bash translate/build.sh      # fresh .mo files + translated metadata.json

OUT="${1:-org.kde.cppserver.plasmoid}"
rm -f "$OUT"
zip -qr "$OUT" metadata.json contents -x '*.pyc' -x '*~'
echo "Created $OUT ($(du -h "$OUT" | cut -f1))"
unzip -l "$OUT" | tail -n +4 | head -n -2 | awk '{print "  " $4}'
