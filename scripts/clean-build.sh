#!/bin/bash
set -euo pipefail

# Prunes generated state under .build. Sources, runtimes and release images are
# never touched by the default mode, so cleaning is safe at any time: the next
# build recreates whatever it needs.
#
#   scripts/clean-build.sh          release history, staging, scratch trees, stale logs
#   scripts/clean-build.sh --deep   also drop runtime rebuild caches and SwiftPM caches
#   scripts/clean-build.sh --all    delete the whole .build directory (full rebuild)

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repository_root/.build"

usage() {
    /usr/bin/sed -n '3,10p' "$0" >&2
    exit 64
}

mode="default"
case "${1:-}" in
    ""|--default) ;;
    --deep) mode="deep" ;;
    --all) mode="all" ;;
    -h|--help) usage ;;
    *) usage ;;
esac
[[ $# -le 1 ]] || usage

[[ -d "$build_root" ]] || { echo "Nothing to clean: $build_root does not exist."; exit 0; }

before_kib="$(/usr/bin/du -sk "$build_root" | /usr/bin/awk '{print $1}')"

remove() {
    local path
    for path in "$@"; do
        [[ -e "$path" ]] || continue
        /bin/rm -rf "$path"
        echo "removed ${path#"$repository_root"/}"
    done
}

if [[ "$mode" == "all" ]]; then
    echo "Removing the entire build directory; runtimes must be rebuilt." >&2
    /bin/rm -rf "$build_root"
else
    release_root="$build_root/out/Products/Release"

    # Release history and staging. The newest DMG stays in place.
    remove "$release_root/previous" "$release_root/staging" "$release_root/DevStack.app"
    if [[ -d "$release_root" ]]; then
        while IFS= read -r old_image; do
            [[ -n "$old_image" ]] && remove "$old_image"
        done < <(/bin/ls -1t "$release_root"/DevStack-*-arm64.dmg 2>/dev/null | /usr/bin/tail -n +2)
    fi

    # Scratch trees, recreated by the next runtime build.
    remove "$build_root/runtime-work" "$build_root/runtime-test-fixtures" \
        "$build_root/build-tools-work" "$build_root/backups"

    # Stray intermediates from earlier tooling and UI review runs.
    remove "$build_root/preview" "$build_root/ui-review" "$build_root/DevStack.iconset" \
        "$build_root/dmg-preview.png" \
        "$build_root/changed-mach-o-files" "$build_root/add-runtimes.py"

    # Logs: keep packaging history, drop one-off build logs and sample captures.
    if [[ -d "$build_root/logs" ]]; then
        /usr/bin/find "$build_root/logs" -maxdepth 1 -type f \( -name '*.log' -o -name '*.txt' \) \
            ! -name 'package-*.log' -delete
    fi

    if [[ "$mode" == "deep" ]]; then
        # Rebuild caches and host toolchains. Re-fetch sources and run
        # scripts/verify-sources.sh before packaging so the image can include
        # its CorrespondingSources payload again.
        remove "$build_root/runtime-dependencies" "$build_root/runtime-cache" \
            "$build_root/build-tools" "$build_root/build-tools-cache"
        /bin/rm -rf "$build_root/out/Intermediates.noindex" "$build_root/out/ModuleCache.noindex" \
            "$build_root/out/CompilationCache.noindex" "$build_root/out/SDKExplicitPrecompiledModules" \
            "$build_root/out/SDKStatCaches.noindex" "$build_root/out/PCH" "$build_root/out/v5"
        echo "removed SwiftPM/Xcode build caches"
    fi
fi

after_kib="$(/usr/bin/du -sk "$build_root" 2>/dev/null | /usr/bin/awk '{print $1}')"
/usr/bin/python3 - "$before_kib" "${after_kib:-0}" <<'PY'
import sys
before, after = (int(value) for value in sys.argv[1:3])
def human(kib): return f"{kib / 1024 / 1024:,.1f} GiB"
print(f"build directory: {human(before)} -> {human(after)} (freed {human(before - after)})")
PY
