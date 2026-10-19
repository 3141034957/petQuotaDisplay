#!/bin/zsh
set -euo pipefail

label="com.erenshwang.petquotadisplay"
launch_domain="gui/$(id -u)"
installed_plist="${HOME}/Library/LaunchAgents/${label}.plist"

launchctl bootout "${launch_domain}/${label}" 2>/dev/null || true
rm -f "${installed_plist}"

echo "Autostart removed: ${installed_plist}"
echo "Application, accounts, and preferences have been preserved."
