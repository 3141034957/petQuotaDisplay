#!/bin/zsh
set -euo pipefail

usage() {
    printf '%s\n' '用法：zsh scripts/install_autostart.sh [显示模式] [--dry-run]' \
        '      zsh scripts/install_autostart.sh --status' \
        '显示模式：--follow-codex、--follow-codex-desktop、--follow-codex-cli、--always-show'
}

mode=""
show_status=false
dry_run=false
for argument in "$@"; do
    case "${argument}" in
        --follow-codex|--follow-codex-desktop|--follow-codex-cli|--always-show)
            if [[ -n "${mode}" ]]; then usage >&2; exit 2; fi
            mode="${argument}"
            ;;
        --status) show_status=true ;;
        --dry-run) dry_run=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ "${show_status}" == true && ( -n "${mode}" || "${dry_run}" == true ) ]]; then
    usage >&2
    exit 2
fi

script_dir="${0:A:h}"
repository_dir="${script_dir:h}"
install_dir="${HOME}/Library/Application Support/PetQuotaDisplay"
launch_agents_dir="${HOME}/Library/LaunchAgents"
label="com.erenshwang.petquotadisplay"
installed_binary="${install_dir}/PetQuotaDisplay"
installed_plist="${launch_agents_dir}/${label}.plist"
launch_domain="gui/$(id -u)"

read_installed_mode() {
    /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "${installed_plist}" >/dev/null 2>&1 || return 1
    local argument
    argument="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "${installed_plist}" 2>/dev/null || true)"
    printf '%s\n' "${argument:---always-show}"
}

if [[ "${show_status}" == true ]]; then
    if [[ -x "${installed_binary}" ]]; then
        printf '%s\n' '程序：已安装'
    else
        printf '%s\n' '程序：未安装或不可执行'
    fi
    if [[ ! -f "${installed_plist}" ]]; then
        printf '%s\n' '自启动配置：未安装'
    elif ! launch_argument="$(read_installed_mode)"; then
        printf '%s\n' '自启动配置：无法读取'
    else
        case "${launch_argument}" in
            --follow-codex) printf '%s\n' '自启动配置：跟随 Codex' ;;
            --follow-codex-desktop) printf '%s\n' '自启动配置：跟随 Codex 桌面端' ;;
            --follow-codex-cli) printf '%s\n' '自启动配置：跟随独立 Codex CLI' ;;
            --always-show) printf '%s\n' '自启动配置：登录后显示额度' ;;
            *) printf '%s\n' '自启动配置：启动模式无法识别' ;;
        esac
    fi
    if launchctl print "${launch_domain}/${label}" >/dev/null 2>&1; then
        printf '%s\n' 'LaunchAgent：已加载'
    else
        printf '%s\n' 'LaunchAgent：当前会话中未检测到'
    fi
    exit 0
fi

if [[ -z "${mode}" ]]; then
    mode=--follow-codex
    if [[ -f "${installed_plist}" ]] && launch_argument="$(read_installed_mode)"; then
        case "${launch_argument}" in
            --follow-codex|--follow-codex-desktop|--follow-codex-cli|--always-show) mode="${launch_argument}" ;;
        esac
    fi
fi

if [[ "${dry_run}" == true ]]; then
    printf '程序路径：%s\nLaunchAgent 路径：%s\n拟采用模式：%s\n' \
        "${installed_binary}" "${installed_plist}" "${mode}"
    exit 0
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
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 ${mode}" "${staged_plist}"
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
