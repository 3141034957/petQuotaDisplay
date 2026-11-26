#!/bin/zsh
set -euo pipefail

usage() {
    printf '%s\n' '用法：zsh scripts/install_autostart.sh [--follow-codex | --always-show]'
}

mode="${1:-}"
if (( $# > 1 )); then
    usage >&2
    exit 2
fi
case "${mode}" in
    ""|--follow-codex|--always-show) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

script_dir="${0:A:h}"
repository_dir="${script_dir:h}"
install_dir="${HOME}/Library/Application Support/PetQuotaDisplay"
launch_agents_dir="${HOME}/Library/LaunchAgents"
label="com.erenshwang.petquotadisplay"
installed_binary="${install_dir}/PetQuotaDisplay"
installed_plist="${launch_agents_dir}/${label}.plist"
launch_domain="gui/$(id -u)"

if [[ -z "${mode}" ]]; then
    mode=--follow-codex
    if [[ -f "${installed_plist}" ]] &&
        /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "${installed_plist}" >/dev/null 2>&1 &&
        ! /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "${installed_plist}" >/dev/null 2>&1; then
        mode=--always-show
    fi
fi

cd "${repository_dir}"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"

mkdir -p "${install_dir}" "${launch_agents_dir}"
staged_binary=""
staged_plist=""
cleanup_staging() {
    [[ -z "${staged_binary}" ]] || rm -f "${staged_binary}"
    [[ -z "${staged_plist}" ]] || rm -f "${staged_plist}"
}
trap cleanup_staging EXIT
staged_binary="$(mktemp "${install_dir}/.PetQuotaDisplay.XXXXXX")"
staged_plist="$(mktemp "${launch_agents_dir}/.${label}.XXXXXX")"
cp "${repository_dir}/autostart/${label}.plist" "${staged_plist}"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${installed_binary}" "${staged_plist}"
if [[ "${mode}" == --always-show ]]; then
    /usr/libexec/PlistBuddy -c 'Delete :ProgramArguments:1' "${staged_plist}"
fi
/usr/bin/plutil -lint "${staged_plist}"
cp "${binary_dir}/PetQuotaDisplay" "${staged_binary}"
chmod 755 "${staged_binary}"
mv -f "${staged_binary}" "${installed_binary}"
staged_binary=""
mv -f "${staged_plist}" "${installed_plist}"
staged_plist=""

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
echo "Mode: ${mode}"
