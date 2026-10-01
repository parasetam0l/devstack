#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="${DEVSTACK_RUNTIME_OUTPUT:-$repository_root/.build/Runtimes}"
release_root="${DEVSTACK_RELEASE_ROOT:-$repository_root/.build/release}"
build_stamp="$(date +%Y%m%d-%H%M%S)-$$"
staging_root="$release_root/staging/$build_stamp"
application="$staging_root/DevStack.app"
identity="${DEVSTACK_SIGNING_IDENTITY:--}"
release_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$repository_root/Packaging/Info.plist")"
release_name="DevStack-$release_version-arm64.dmg"

[[ "$(uname -m)" == "arm64" ]] || { echo "Release packaging requires Apple Silicon." >&2; exit 69; }
[[ -d "$runtime_root" ]] || { echo "Runtime payload is missing: $runtime_root" >&2; exit 66; }

runtime_ids=(apache-2.4 nginx-1.30 php-8.4 php-8.5 mysql-8.4 postgresql-18 openssl-3.5 mailpit-1.31.1 phpmyadmin-5.2.3 adminer-6.1.1 composer-2.10.3 imagemagick-7.1)
# Optional legacy payloads enter the release only after their feasibility gates pass.
if [[ "${DEVSTACK_INCLUDE_LEGACY:-0}" == "1" ]]; then
    for runtime_id in php-7.4 mysql-5.7; do
        gate=php74
        [[ "$runtime_id" != "mysql-5.7" ]] || gate=mysql57
        if [[ -d "$runtime_root/$runtime_id" ]] && "$repository_root/scripts/gates/$gate.sh"; then
            runtime_ids+=("$runtime_id")
        else
            echo "Omitting unverified legacy payload: $runtime_id" >&2
        fi
    done
fi
cd "$repository_root"
swift build -c release --jobs "${DEVSTACK_BUILD_JOBS:-2}"
products="$(swift build -c release --show-bin-path)"
"$products/DevStackCoreChecks"
mkdir -p "$application/Contents/MacOS" \
    "$application/Contents/Resources/Runtimes" \
    "$application/Contents/Library/LaunchServices" \
    "$application/Contents/Library/LaunchDaemons"

cp "$repository_root/Packaging/Info.plist" "$application/Contents/Info.plist"
cp "$repository_root/Sources/DevStackApp/Resources/DevStack.icns" "$application/Contents/Resources/DevStack.icns"
cp "$products/DevStack" "$application/Contents/MacOS/DevStack"
cp "$products/DevStackPrivilegedHelper" "$application/Contents/Library/LaunchServices/DevStackPrivilegedHelper"
cp "$repository_root/Sources/DevStackApp/Resources/app.devstack.desktop.helper.plist" "$application/Contents/Library/LaunchDaemons/app.devstack.desktop.helper.plist"
cp "$repository_root/Sources/DevStackApp/Resources/runtime-lock.json" "$application/Contents/Resources/runtime-lock.json"
for runtime_id in "${runtime_ids[@]}"; do
    [[ -d "$runtime_root/$runtime_id" ]] || { echo "Missing runtime: $runtime_id" >&2; exit 66; }
    cp -cR "$runtime_root/$runtime_id" "$application/Contents/Resources/Runtimes/$runtime_id"
done
"$repository_root/scripts/audit-runtime.sh" "$application/Contents/Resources/Runtimes" "$repository_root/.build/runtime-work"
for resource_bundle in "$products"/*.bundle; do
    [[ -d "$resource_bundle" ]] && cp -R "$resource_bundle" "$application/Contents/Resources/"
done

if [[ -d "$repository_root/ThirdPartyNotices" ]]; then cp -R "$repository_root/ThirdPartyNotices" "$application/Contents/Resources/ThirdPartyNotices"; fi
"$repository_root/scripts/generate-sbom.py" "$application/Contents/Resources/Runtimes" "$application/Contents/Resources/SBOM/runtime-sbom.cdx.json"
source_cache="${DEVSTACK_SOURCE_CACHE:-$repository_root/.build/runtime-cache}"
if [[ -d "$source_cache" ]]; then cp -R "$source_cache" "$application/Contents/Resources/CorrespondingSources"; fi
mkdir -p "$application/Contents/Resources/CorrespondingSources/DevStackPatches"
cp "$repository_root/scripts/prepare-imagemagick.py" "$repository_root/scripts/configure-phpmyadmin.py" "$application/Contents/Resources/CorrespondingSources/DevStackPatches/"
cp "$repository_root/LICENSE" "$application/Contents/Resources/LICENSE"

signing_options=(--options runtime --timestamp)
if [[ "$identity" == "-" ]]; then
    signing_options=(--timestamp=none)
    echo "No Developer ID identity configured: producing an ad-hoc development build." >&2
fi
while IFS= read -r -d '' binary; do
    if /usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign --force "${signing_options[@]}" --sign "$identity" "$binary"
    fi
done < <(/usr/bin/python3 "$repository_root/scripts/mach-o-files.py" "$application/Contents/Resources/Runtimes")

/usr/bin/codesign --force "${signing_options[@]}" --entitlements "$repository_root/Packaging/Helper.entitlements" --sign "$identity" "$application/Contents/Library/LaunchServices/DevStackPrivilegedHelper"
/usr/bin/codesign --force "${signing_options[@]}" --entitlements "$repository_root/Packaging/DevStack.entitlements" --sign "$identity" "$application"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$application"

# The helper's XPC trust requires app and helper to share one Developer ID Team.
# Catch a mismatched / ad-hoc sign here instead of a silent helper failure later.
if [[ "$identity" != "-" ]]; then
    app_team=$(/usr/bin/codesign -dv "$application" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | head -n 1)
    helper_team=$(/usr/bin/codesign -dv "$application/Contents/Library/LaunchServices/DevStackPrivilegedHelper" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | head -n 1)
    [[ -n "${app_team:-}" && "$app_team" != "not set" ]] || { echo "App has no TeamIdentifier after signing." >&2; exit 70; }
    [[ "$app_team" == "$helper_team" ]] || { echo "Team mismatch: app=$app_team helper=$helper_team. Helper XPC trust would fail." >&2; exit 70; }
    /usr/bin/plutil -lint "$application/Contents/Library/LaunchDaemons/app.devstack.desktop.helper.plist" >/dev/null
    /usr/bin/python3 - "$application/Contents/Library/LaunchDaemons/app.devstack.desktop.helper.plist" <<'EOF'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
assert info.get("Label") == "app.devstack.desktop.helper", "Label"
assert info.get("MachServices", {}).get("app.devstack.desktop.helper") is True, "MachServices"
assert info.get("BundleProgram") == "Contents/Library/LaunchServices/DevStackPrivilegedHelper", "BundleProgram"
assert "app.devstack.desktop" in info.get("AssociatedBundleIdentifiers", []), "AssociatedBundleIdentifiers"
EOF
    echo "Signed: $identity (Team $app_team). App and helper teams match." >&2
fi

dmg="$staging_root/$release_name"
dmg_root="$staging_root/dmg-root"
rm -rf "$dmg_root"
mkdir -p "$dmg_root"
cp -cR "$application" "$dmg_root/DevStack.app"
ln -s /Applications "$dmg_root/Applications"
/usr/sbin/diskutil image create from --volumeName DevStack --format UDZO "$dmg_root" "$dmg"
rm -rf "$dmg_root"
/usr/bin/codesign --force "${signing_options[@]}" --sign "$identity" "$dmg"

if [[ -n "${DEVSTACK_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$DEVSTACK_NOTARY_PROFILE" --wait
    xcrun stapler staple "$application"
    xcrun stapler staple "$dmg"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
else
    echo "DEVSTACK_NOTARY_PROFILE is unset; DMG was signed but not notarized or stapled." >&2
fi

mkdir -p "$release_root/previous/$build_stamp"
for artifact in DevStack.app "$release_name"; do
    if [[ -e "$release_root/$artifact" ]]; then mv "$release_root/$artifact" "$release_root/previous/$build_stamp/"; fi
    mv "$staging_root/$artifact" "$release_root/$artifact"
done
echo "Release image: $release_root/$release_name"
echo "Next: copy DevStack.app to /Applications via the DMG, open it from Finder (not swift run / preview)," >&2
echo "then Settings → System integration → Set Up and approve in Login Items & Extensions." >&2
