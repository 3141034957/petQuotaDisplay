#!/bin/zsh
set -euo pipefail

usage() {
    printf '%s\n' '用法：zsh scripts/package_app.sh [输出目录]'
}

if (( $# > 1 )); then
    usage >&2
    exit 2
fi
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
esac

script_dir="${0:A:h}"
repository_dir="${script_dir:h}"
output="${1:-${repository_dir}/.build/distribution}"
output="${output:A}"

cd "${repository_dir}"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"

mkdir -p "${output}"
distribution="$(mktemp -d "${output}/PetQuotaDisplay.XXXXXX")"
completed=false
cleanup() {
    [[ "${completed}" == true ]] || rm -rf "${distribution}"
}
trap cleanup EXIT

app="${distribution}/PetQuotaDisplay.app"
mkdir -p "${app}/Contents/MacOS"
cp "${repository_dir}/packaging/Info.plist" "${app}/Contents/Info.plist"
cp "${binary_dir}/PetQuotaDisplay" "${app}/Contents/MacOS/PetQuotaDisplay"
/usr/bin/plutil -lint "${app}/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "${app}"
/usr/bin/codesign --verify --strict "${app}"

completed=true
printf 'App：%s\n' "${app}"
