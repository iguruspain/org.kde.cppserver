#!/usr/bin/env bash
# uninstall.sh – cpp servers Plasmoid Uninstaller
# Run WITHOUT sudo: bash uninstall.sh [--no-restart]
# Running servers, logs and ~/.config/cppserver/servers.json are not touched.
set -euo pipefail

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Do not run as root." >&2
    exit 1
fi

RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

PLASMOID_ID="org.kde.cppserver"

if kpackagetool6 --list --type Plasma/Applet 2>/dev/null | grep -q "$PLASMOID_ID"; then
    kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID"
    echo "Removed $PLASMOID_ID"
else
    echo "$PLASMOID_ID is not installed."
fi

# Drop Plasma's compiled-QML cache so no stale copy survives.
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/plasmashell/qmlcache" 2>/dev/null || true

if [ "$RESTART" -eq 1 ]; then
    if systemctl --user is-active --quiet plasma-plasmashell.service 2>/dev/null; then
        systemctl --user restart plasma-plasmashell.service
    else
        kquitapp6 plasmashell 2>/dev/null || true
        sleep 1
        (kstart plasmashell || kstart6 plasmashell) &>/dev/null &
    fi
fi
