#!/bin/bash
#
# Pins runtime packs published by devstack-runtimes in
# Sources/DevStackApp/Resources/runtime-packs.json, the exact packs this
# version of DevStack installs.
#
#   scripts/pin-runtime.sh PACK_NAME...   pin published packs, e.g. php-8.5-8.5.11-r1
#   scripts/pin-runtime.sh --check        re-download every pinned pack and check it
#
# A pack is pinned only after its download matches the size and SHA-256 its
# release states in pack.json. Replacing a runtime's pin replaces its entry.

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
catalog="$repository_root/Sources/DevStackApp/Resources/runtime-packs.json"
releases="https://github.com/parasetam0l/devstack-runtimes/releases/download"
work="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$work"' EXIT

fetch() {
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 --output "$2" "$1"
}

check_download() {  # check_download URL SIZE SHA256 LABEL
    local file="$work/pack"
    fetch "$1" "$file"
    [[ "$(/usr/bin/stat -f %z "$file")" == "$2" ]] || { echo "$4: the download has the wrong size." >&2; exit 65; }
    [[ "$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')" == "$3" ]] || { echo "$4: the download does not match its SHA-256." >&2; exit 65; }
    /bin/rm -f "$file"
}

if [[ "${1:-}" == "--check" ]]; then
    while IFS=$'\t' read -r name url size sha256; do
        [[ -n "$name" ]] || continue
        check_download "$url" "$size" "$sha256" "$name"
        echo "verified $name"
    done <<< "$(/usr/bin/python3 -c '
import json, sys
for pack in json.load(open(sys.argv[1]))["packs"]:
    print("\t".join([pack["name"], pack["url"], str(pack["size"]), pack["sha256"]]))
' "$catalog")"
    exit 0
fi

[[ $# -gt 0 ]] || { /usr/bin/sed -n '3,12p' "$0" >&2; exit 64; }
for name in "$@"; do
    [[ "$name" =~ ^[a-z0-9][a-z0-9.+-]*-r[0-9]+$ ]] || { echo "Not a pack name: $name" >&2; exit 64; }
    fetch "$releases/$name/pack.json" "$work/pack.json"
    read -r file size sha256 < <(/usr/bin/python3 - "$work/pack.json" "$name" <<'PY'
import json, re, sys
pack = json.load(open(sys.argv[1]))
if pack.get("schemaVersion") != 1 or pack.get("name") != sys.argv[2]:
    raise SystemExit(f"pack.json does not describe {sys.argv[2]}")
if not re.fullmatch(r"[0-9a-f]{64}", pack["sha256"]) or pack["file"] != pack["name"] + ".devstack-runtime":
    raise SystemExit("pack.json is malformed")
print(pack["file"], pack["size"], pack["sha256"])
PY
)
    check_download "$releases/$name/$file" "$size" "$sha256" "$name"
    /usr/bin/python3 - "$catalog" "$work/pack.json" "$releases/$name/$file" <<'PY'
import json, sys
catalog_path, pack_path, url = sys.argv[1:4]
catalog = json.load(open(catalog_path))
pack = json.load(open(pack_path))
pin = {key: pack[key] for key in ("id", "version", "packRevision", "name", "sha256", "size", "requires", "minimumMacOS", "contents")}
pin["url"] = url
catalog["packs"] = sorted([entry for entry in catalog["packs"] if entry["id"] != pin["id"]] + [pin], key=lambda entry: entry["id"])
open(catalog_path, "w").write(json.dumps(catalog, indent=2, sort_keys=True) + "\n")
PY
    echo "pinned $name"
done
