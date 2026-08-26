#!/bin/zsh
set -euo pipefail

label="com.erenshwang.petquotadisplay"
launch_domain="gui/$(id -u)"
installed_plist="${HOME}/Library/LaunchAgents/${label}.plist"

launchctl bootout "${launch_domain}/${label}" 2>/dev/null || true

echo "Autostart disabled. You can remove these files if no longer needed:"
echo "${installed_plist}"
echo "${HOME}/Library/Application Support/PetQuotaDisplay"
