#!/bin/bash
# Preflight for the privileged helper: fails fast on the signature/plist
# defects that surface only as a launchd exec kill or a silent timeout.
set -euo pipefail

app="${1:-.build/release/DevStack.app}"
helper="$app/Contents/Library/LaunchServices/DevStackPrivilegedHelper"
plist="$app/Contents/Library/LaunchDaemons/app.devstack.desktop.helper.plist"
fail=0

say() { echo "$1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

[[ -d "$app" ]] || { bad "app bundle missing: $app"; exit 1; }
[[ -f "$helper" ]] || { bad "helper binary missing: $helper"; exit 1; }
[[ -f "$plist" ]] || { bad "daemon plist missing: $plist"; exit 1; }

/usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
    || bad "codesign --verify --deep --strict failed"

app_team=$(/usr/bin/codesign -dv "$app" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | head -n 1)
helper_team=$(/usr/bin/codesign -dv "$helper" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | head -n 1)
[[ -n "${app_team:-}" && "$app_team" != "not set" ]] || bad "app has no TeamIdentifier"
[[ "$app_team" == "$helper_team" ]] || bad "team mismatch app=$app_team helper=$helper_team"
say "teams: app=$app_team helper=$helper_team"

# A sandboxed (or sandbox-marked) system daemon is killed at exec with a
# Launch Constraint Violation, while the same binary runs fine standalone.
if /usr/bin/codesign -d --entitlements - "$helper" 2>/dev/null | /usr/bin/grep -q "app-sandbox"; then
    bad "helper carries com.apple.security.app-sandbox entitlement material"
else
    say "helper entitlements: no app-sandbox key"
fi

/usr/bin/plutil -lint "$plist" >/dev/null || bad "daemon plist is not valid plist"
/usr/bin/python3 - "$plist" <<'EOF'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
assert info.get("Label") == "app.devstack.desktop.helper", "Label"
assert info.get("MachServices", {}).get("app.devstack.desktop.helper") is True, "MachServices"
assert info.get("BundleProgram") == "Contents/Library/LaunchServices/DevStackPrivilegedHelper", "BundleProgram"
assert "app.devstack.desktop" in info.get("AssociatedBundleIdentifiers", []), "AssociatedBundleIdentifiers"
print("daemon plist: Label/MachServices/BundleProgram/AssociatedBundleIdentifiers OK")
EOF

if /usr/bin/spctl --assess --type execute --verbose=2 "$app" 2>&1 | /usr/bin/grep -q "accepted"; then
    say "gatekeeper: app accepted"
else
    say "gatekeeper: app NOT accepted (helper exec may still be refused; notarize + staple)"
fi

recent=$(ls -t /Library/Logs/DiagnosticReports/DevStackPrivilegedHelper-*.ips 2>/dev/null | head -n 1 || true)
[[ -n "$recent" ]] && say "newest helper crash report: $recent" || say "no helper crash reports"

exit $fail
