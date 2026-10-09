#!/usr/bin/env bash
# ============================================================
# install.sh – cpp servers Plasmoid Installer (Plasma 6)
# Run WITHOUT sudo:   bash install.sh [--no-restart]
# ============================================================
set -euo pipefail

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Do not run as root." >&2
    exit 1
fi

RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

PLASMOID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLASMOID_ID="org.kde.cppserver"

echo "================================================="
echo "  cpp servers Plasmoid - Installer"
echo "================================================="

chmod +x "$PLASMOID_DIR/contents/scripts/cppserverctl.sh"

# Compile translations (po/*.po -> contents/locale/*/*.mo, metadata.json).
if [ -f "$PLASMOID_DIR/translate/build.sh" ]; then
    bash "$PLASMOID_DIR/translate/build.sh" || echo "Warning: translations were not built." >&2
fi

# Clean reinstall: --upgrade can leave the old files in place, and Plasma keeps
# a compiled-QML cache that would keep serving them.
if kpackagetool6 --list --type Plasma/Applet 2>/dev/null | grep -q "$PLASMOID_ID"; then
    kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID" || true
fi
kpackagetool6 --type Plasma/Applet --install "$PLASMOID_DIR"
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/plasmashell/qmlcache" 2>/dev/null || true

INSTALLED="$HOME/.local/share/plasma/plasmoids/$PLASMOID_ID"
if [ -d "$INSTALLED" ]; then
    echo "Installed version: $(grep -o '"Version": *"[^"]*"' "$INSTALLED/metadata.json" | head -1)"
    if grep -rq "logFilter" "$INSTALLED/contents" 2>/dev/null; then
        echo "WARNING: $INSTALLED still contains old files." >&2
    fi
fi

# Plasma caches QML: restart the shell so the new version is loaded.
if [ "$RESTART" -eq 1 ]; then
    if systemctl --user is-active --quiet plasma-plasmashell.service 2>/dev/null; then
        systemctl --user restart plasma-plasmashell.service
    else
        kquitapp6 plasmashell 2>/dev/null || true
        sleep 1
        (kstart plasmashell || kstart6 plasmashell) &>/dev/null &
    fi
fi

echo ""
echo "Installed. Add the widget: right-click desktop -> Add Widgets -> 'cpp servers'"
echo "Servers are stored in: ${XDG_CONFIG_HOME:-$HOME/.config}/cppserver/servers.json"
echo "Logs are stored in:    ${XDG_CACHE_HOME:-$HOME/.cache}/cppserver/logs"
echo ""
echo "Tip (no restart needed while developing):  plasmoidviewer -a \"$PLASMOID_DIR\""
