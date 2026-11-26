#!/bin/zsh
set -euo pipefail

usage() {
    printf '%s\n' '用法：zsh scripts/package_app.sh [--zip] [输出目录]'
}

output=""
zip_app=false
for argument in "$@"; do
    case "${argument}" in
        -h|--help) usage; exit 0 ;;
        --zip) zip_app=true ;;
        -*) usage >&2; exit 2 ;;
        *)
            if [[ -n "${output}" ]]; then
                usage >&2
                exit 2
            fi
            output="${argument}"
            ;;
    esac
done

script_dir="${0:A:h}"
repository_dir="${script_dir:h}"
output="${output:-${repository_dir}/.build/distribution}"
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
if build_revision="$(git rev-parse --short=12 HEAD 2>/dev/null)"; then
    if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
        build_revision+="+dirty"
    fi
    /usr/libexec/PlistBuddy -c "Add :PetQuotaDisplayRevision string ${build_revision}" "${app}/Contents/Info.plist"
fi
/usr/bin/plutil -lint "${app}/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "${app}"
/usr/bin/codesign --verify --strict "${app}"

if [[ "${zip_app}" == true ]]; then
    archive="${distribution}/PetQuotaDisplay.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app}" "${archive}"
    /usr/bin/unzip -tq "${archive}"
fi

completed=true
printf 'App：%s\n' "${app}"
if [[ "${zip_app}" == true ]]; then
    printf 'ZIP：%s\n' "${archive}"
fi
