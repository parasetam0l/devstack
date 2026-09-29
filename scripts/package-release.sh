#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="${DEVSTACK_RUNTIME_OUTPUT:-$repository_root/.build/Runtimes}"
release_root="${DEVSTACK_RELEASE_ROOT:-$repository_root/.build/release}"
application="$release_root/DevStack.app"
identity="${DEVSTACK_SIGNING_IDENTITY:--}"

[[ "$(uname -m)" == "arm64" ]] || { echo "Release packaging requires Apple Silicon." >&2; exit 69; }
[[ -d "$runtime_root" ]] || { echo "Runtime payload is missing: $runtime_root" >&2; exit 66; }

# Legacy runtimes are fail-closed: a failed feasibility gate removes the runtime
# from this release instead of shipping an unverified payload.
enforce_legacy_gate() {
    local runtime_id="$1" gate="$2"
    if [[ ! -d "$runtime_root/$runtime_id" ]]; then
        echo "Legacy runtime $runtime_id is not present; it will not be packaged." >&2
        return 0
    fi
    if "$repository_root/scripts/gates/$gate.sh"; then
        return 0
    fi
    echo "Feasibility gate failed for $runtime_id; omitting it from this release." >&2
    rm -rf "$runtime_root/$runtime_id"
}

enforce_legacy_gate php-7.4 php74
enforce_legacy_gate mysql-5.7 mysql57

swift build -c release --arch arm64
swift run -c release --arch arm64 DevStackCoreChecks
products="$(swift build -c release --arch arm64 --show-bin-path)"
rm -rf "$release_root"
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
cp -R "$runtime_root/." "$application/Contents/Resources/Runtimes/"
for resource_bundle in "$products"/*.bundle; do
    [[ -d "$resource_bundle" ]] && cp -R "$resource_bundle" "$application/Contents/Resources/"
done

if [[ -d "$repository_root/ThirdPartyNotices" ]]; then cp -R "$repository_root/ThirdPartyNotices" "$application/Contents/Resources/ThirdPartyNotices"; fi
"$repository_root/scripts/generate-sbom.py" "$runtime_root" "$application/Contents/Resources/SBOM/runtime-sbom.cdx.json"
source_cache="${DEVSTACK_SOURCE_CACHE:-$repository_root/.build/runtime-cache}"
if [[ -d "$source_cache" ]]; then cp -R "$source_cache" "$application/Contents/Resources/CorrespondingSources"; fi
cp "$repository_root/LICENSE" "$application/Contents/Resources/LICENSE"

while IFS= read -r -d '' binary; do
    if /usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$binary"
    fi
done < <(/usr/bin/find "$application/Contents/Resources/Runtimes" -type f -print0)

/usr/bin/codesign --force --options runtime --timestamp --entitlements "$repository_root/Packaging/Helper.entitlements" --sign "$identity" "$application/Contents/Library/LaunchServices/DevStackPrivilegedHelper"
/usr/bin/codesign --force --options runtime --timestamp --entitlements "$repository_root/Packaging/DevStack.entitlements" --sign "$identity" "$application"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$application"

dmg="$release_root/DevStack-0.1.0-arm64.dmg"
/usr/bin/hdiutil create -volname DevStack -srcfolder "$application" -ov -format UDZO "$dmg"
/usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"

if [[ -n "${DEVSTACK_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$DEVSTACK_NOTARY_PROFILE" --wait
    xcrun stapler staple "$application"
    xcrun stapler staple "$dmg"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
else
    echo "DEVSTACK_NOTARY_PROFILE is unset; DMG was signed but not notarized or stapled." >&2
fi

echo "Release image: $dmg"
