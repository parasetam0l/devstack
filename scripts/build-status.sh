#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

echo "DevStack build status — $(date '+%H:%M:%S')"
echo

echo "Active build processes:"
if pgrep -fl "build-dependencies\.sh|build-runtimes\.sh|build-component\.sh" >/dev/null 2>&1; then
    pgrep -fl "build-dependencies\.sh|build-runtimes\.sh|build-component\.sh" | sed 's/^/  /'
else
    echo "  (none)"
fi
echo

echo "Logs (newest last line):"
for log in .build/logs/*.log; do
    [[ -f "$log" ]] || continue
    printf "  %s  [%s]\n" "$log" "$(/usr/bin/stat -f '%Sm' -t '%H:%M:%S' "$log")"
    /usr/bin/tail -n 2 "$log" | sed 's/^/    /'
done
echo

echo "Dependency prefixes:"
if [[ -d .build/runtime-dependencies ]] && [[ -n "$(ls -A .build/runtime-dependencies 2>/dev/null)" ]]; then
    /bin/ls .build/runtime-dependencies | sed 's/^/  /'
else
    echo "  (none yet)"
fi
echo

echo "Runtimes built:"
if [[ -d .build/Runtimes ]] && [[ -n "$(ls -A .build/Runtimes 2>/dev/null)" ]]; then
    /bin/ls .build/Runtimes | sed 's/^/  /'
else
    echo "  (none yet)"
fi
