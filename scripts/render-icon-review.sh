#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
xcode_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
icon_tool="${xcode_developer_dir}/../Applications/Icon Composer.app/Contents/Executables/ictool"
icon_path="${repo_root}/ViewTheWord/Resources/AppIcon.icon"
output_dir="${1:-${repo_root}/build/icon-review}"

if [[ ! -x "${icon_tool}" ]]; then
    echo "Icon Composer's ictool is required. Select Xcode 26 or later with xcode-select or DEVELOPER_DIR." >&2
    exit 1
fi

mkdir -p "${output_dir}"
output_dir="$(cd "${output_dir}" && pwd)"

for rendition in Default Dark TintedLight TintedDark ClearLight ClearDark; do
    "${icon_tool}" "${icon_path}" \
        --export-image \
        --output-file "${output_dir}/${rendition}.png" \
        --platform macOS --rendition "${rendition}" \
        --width 512 --height 512 --scale 1 \
        > "${output_dir}/${rendition}.log"
done

printf 'Icon Composer previews: %s\n' "${output_dir}"
