#!/bin/zsh
set -euo pipefail

usage() {
    printf '%s\n' '用法：zsh scripts/install_autostart.sh [显示模式] [--at-next-login] [--dry-run]' \
        '      zsh scripts/install_autostart.sh [显示模式] --print-plist' \
        '      zsh scripts/install_autostart.sh --status [--json]' \
        '显示模式：--follow-codex、--follow-codex-desktop、--follow-codex-cli、--always-show'
}

mode=""
show_status=false
status_json=false
dry_run=false
at_next_login=false
print_plist=false
for argument in "$@"; do
    case "${argument}" in
        --follow-codex|--follow-codex-desktop|--follow-codex-cli|--always-show)
            if [[ -n "${mode}" ]]; then usage >&2; exit 2; fi
            mode="${argument}"
            ;;
        --status) show_status=true ;;
        --json) status_json=true ;;
        --dry-run) dry_run=true ;;
        --at-next-login) at_next_login=true ;;
        --print-plist) print_plist=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ "${show_status}" == true && ( -n "${mode}" || "${dry_run}" == true || "${print_plist}" == true || "${at_next_login}" == true ) ]] ||
   [[ "${dry_run}" == true && "${print_plist}" == true ]] ||
   [[ "${status_json}" == true && "${show_status}" == false ]]; then
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
    executable=false
    binary_description='未安装或不可执行'
    if [[ -x "${installed_binary}" ]]; then
        executable=true
        binary_description='已安装'
    fi
    configured_mode=null
    if [[ ! -f "${installed_plist}" ]]; then
        configuration=missing
        configuration_description='未安装'
    elif ! launch_argument="$(read_installed_mode)"; then
        configuration=invalid
        configuration_description='无法读取'
    else
        configuration=configured
        case "${launch_argument}" in
            --follow-codex) configuration_description='跟随 Codex' ;;
            --follow-codex-desktop) configuration_description='跟随 Codex 桌面端' ;;
            --follow-codex-cli) configuration_description='跟随独立 Codex CLI' ;;
            --always-show) configuration_description='登录后显示额度' ;;
            *)
                configuration=unknownMode
                configuration_description='启动模式无法识别'
                ;;
        esac
        if [[ "${configuration}" == configured ]]; then
            configured_mode="\"${launch_argument}\""
        fi
    fi
    loaded=false
    launch_description='当前会话中未检测到'
    if launchctl print "${launch_domain}/${label}" >/dev/null 2>&1; then
        loaded=true
        launch_description='已加载'
    fi
    if [[ "${status_json}" == true ]]; then
        printf '{"executable":%s,"configuration":"%s","mode":%s,"loaded":%s}\n' \
            "${executable}" "${configuration}" "${configured_mode}" "${loaded}"
    else
        printf '程序：%s\n自启动配置：%s\nLaunchAgent：%s\n' \
            "${binary_description}" "${configuration_description}" "${launch_description}"
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
    if [[ "${at_next_login}" == true ]]; then
        printf '%s\n' '生效时间：下一次图形登录'
    fi
    exit 0
fi

render_launch_plist() {
    local destination="$1"
    cp "${repository_dir}/autostart/${label}.plist" "${destination}"
    /usr/bin/plutil -replace ProgramArguments -json '[]' "${destination}"
    /usr/bin/plutil -insert ProgramArguments.0 -string "${installed_binary}" "${destination}"
    /usr/bin/plutil -insert ProgramArguments.1 -string "${mode}" "${destination}"
    /usr/bin/plutil -lint -s "${destination}"
}

staged_binary=""
staged_plist=""
cleanup_staging() {
    [[ -z "${staged_binary}" ]] || rm -f "${staged_binary}"
    [[ -z "${staged_plist}" ]] || rm -f "${staged_plist}"
}
trap cleanup_staging EXIT

if [[ "${print_plist}" == true ]]; then
    staged_plist="$(mktemp "${TMPDIR:-/tmp}/PetQuotaDisplay.launch.XXXXXX")"
    render_launch_plist "${staged_plist}"
    cat "${staged_plist}"
    exit 0
fi

if [[ "${at_next_login}" == false ]] && ! launchctl print "${launch_domain}" >/dev/null 2>&1; then
    printf '%s\n' '无法访问当前用户的 macOS 图形会话。可加 --at-next-login 为下次登录准备自启动配置。' >&2
    exit 1
fi

cd "${repository_dir}"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"

mkdir -p "${install_dir}" "${launch_agents_dir}"
staged_binary="$(mktemp "${install_dir}/.PetQuotaDisplay.XXXXXX")"
staged_plist="$(mktemp "${launch_agents_dir}/.${label}.XXXXXX")"
render_launch_plist "${staged_plist}"
cp "${binary_dir}/PetQuotaDisplay" "${staged_binary}"
chmod 755 "${staged_binary}"
mv -f "${staged_binary}" "${installed_binary}"
staged_binary=""
mv -f "${staged_plist}" "${installed_plist}"
staged_plist=""

if [[ "${at_next_login}" == true ]]; then
    printf '程序：%s\nLaunchAgent：%s\n模式：%s\n生效时间：下一次图形登录\n' \
        "${installed_binary}" "${installed_plist}" "${mode}"
    exit 0
fi

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
