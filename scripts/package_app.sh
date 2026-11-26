#!/bin/zsh
set -euo pipefail

usage() {
    printf '%s\n' '用法：zsh scripts/package_app.sh [--universal] [--zip] [--checksum] [--json] [输出目录]' \
        '--checksum 会生成 ZIP 和对应的 SHA-256 校验文件'
}

output=""
zip_app=false
universal=false
checksum=false
json_output=false
for argument in "$@"; do
    case "${argument}" in
        -h|--help) usage; exit 0 ;;
        --zip) zip_app=true ;;
        --universal) universal=true ;;
        --checksum) checksum=true; zip_app=true ;;
        --json) json_output=true ;;
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
build_product() {
    swift build -c release --product PetQuotaDisplay "$@" >&2
    swift build -c release --show-bin-path "$@"
}
if [[ "${universal}" == true ]]; then
    arm_binary_dir="$(build_product --scratch-path .build/package-arm64 --triple arm64-apple-macosx13.0)"
    intel_binary_dir="$(build_product --scratch-path .build/package-x86_64 --triple x86_64-apple-macosx13.0)"
else
    binary_dir="$(build_product)"
fi

mkdir -p "${output}"
distribution="$(mktemp -d "${output}/PetQuotaDisplay.XXXXXX")"
completed=false
report=""
cleanup() {
    [[ -z "${report}" ]] || rm -f "${report}"
    [[ "${completed}" == true ]] || rm -rf "${distribution}"
}
trap cleanup EXIT

app="${distribution}/PetQuotaDisplay.app"
mkdir -p "${app}/Contents/MacOS"
cp "${repository_dir}/packaging/Info.plist" "${app}/Contents/Info.plist"
binary="${app}/Contents/MacOS/PetQuotaDisplay"
if [[ "${universal}" == true ]]; then
    /usr/bin/lipo -create "${arm_binary_dir}/PetQuotaDisplay" "${intel_binary_dir}/PetQuotaDisplay" -output "${binary}"
    /usr/bin/lipo "${binary}" -verify_arch arm64
    /usr/bin/lipo "${binary}" -verify_arch x86_64
else
    cp "${binary_dir}/PetQuotaDisplay" "${binary}"
fi
if build_revision="$(git rev-parse --short=12 HEAD 2>/dev/null)"; then
    if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
        build_revision+="+dirty"
    fi
    /usr/libexec/PlistBuddy -c "Add :PetQuotaDisplayRevision string ${build_revision}" "${app}/Contents/Info.plist"
fi
/usr/bin/plutil -lint "${app}/Contents/Info.plist" >&2
/usr/bin/codesign --force --sign - --timestamp=none "${app}"
/usr/bin/codesign --verify --strict "${app}"

if [[ "${zip_app}" == true ]]; then
    archive="${distribution}/PetQuotaDisplay.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app}" "${archive}"
    /usr/bin/unzip -tq "${archive}" >&2
fi
if [[ "${checksum}" == true ]]; then
    (
        cd "${distribution}"
        /usr/bin/shasum -a 256 PetQuotaDisplay.zip > PetQuotaDisplay.zip.sha256
        /usr/bin/shasum -a 256 -c PetQuotaDisplay.zip.sha256 >&2
    )
fi

if [[ "${json_output}" == true ]]; then
    report="$(mktemp "${TMPDIR:-/tmp}/PetQuotaDisplay.package.XXXXXX")"
    /usr/bin/plutil -create xml1 "${report}"
    /usr/bin/plutil -insert appPath -string "${app}" "${report}"
    if [[ "${zip_app}" == true ]]; then
        /usr/bin/plutil -insert zipPath -string "${archive}" "${report}"
    fi
    if [[ "${checksum}" == true ]]; then
        /usr/bin/plutil -insert checksumPath -string "${archive}.sha256" "${report}"
    fi
    if [[ -n "${build_revision}" ]]; then
        /usr/bin/plutil -insert revision -string "${build_revision}" "${report}"
    fi
    /usr/bin/plutil -convert json -o - "${report}"
    printf '\n'
else
    printf 'App：%s\n' "${app}"
    if [[ "${zip_app}" == true ]]; then
        printf 'ZIP：%s\n' "${archive}"
    fi
    if [[ "${checksum}" == true ]]; then
        printf 'SHA-256：%s\n' "${archive}.sha256"
    fi
fi
completed=true
