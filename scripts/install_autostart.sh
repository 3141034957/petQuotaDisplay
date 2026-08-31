#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repository_dir="${script_dir:h}"
install_dir="${HOME}/Library/Application Support/PetQuotaDisplay"
launch_agents_dir="${HOME}/Library/LaunchAgents"
label="com.erenshwang.petquotadisplay"
installed_binary="${install_dir}/PetQuotaDisplay"
installed_plist="${launch_agents_dir}/${label}.plist"
launch_domain="gui/$(id -u)"

cd "${repository_dir}"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"

mkdir -p "${install_dir}" "${launch_agents_dir}"
cp "${binary_dir}/PetQuotaDisplay" "${installed_binary}"
cp "${repository_dir}/autostart/${label}.plist" "${installed_plist}"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${installed_binary}" "${installed_plist}"

launchctl bootout "${launch_domain}/${label}" 2>/dev/null || true
launchctl enable "${launch_domain}/${label}"
bootstrap_status=1
for attempt in 1 2 3; do
    if launchctl bootstrap "${launch_domain}" "${installed_plist}"; then
        bootstrap_status=0
        break
    fi
    /bin/sleep 1
done
(( bootstrap_status == 0 ))

echo "Installed: ${installed_binary}"
echo "LaunchAgent: ${installed_plist}"
