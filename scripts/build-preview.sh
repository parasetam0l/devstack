#!/bin/bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
preview_root="$repository_root/.build/preview"
build_stamp="$(date +%Y%m%d-%H%M%S)-$$"
application="$preview_root/staging/$build_stamp/DevStack.app"
# Like a release, a preview holds no runtimes: it uses the packs installed
# from its Runtimes page.
cd "$repository_root"
if [[ "${DEVSTACK_INSTALL_PREVIEW:-0}" == "1" ]] && /usr/bin/pgrep -x DevStack >/dev/null; then
    echo "Quit DevStack before replacing the installed app." >&2
    exit 75
fi
source "$repository_root/scripts/swift-link-options.sh"
swift build --jobs "${DEVSTACK_BUILD_JOBS:-2}" "${swift_link_options[@]}"
products="$(swift build --show-bin-path)"
check_sdk_version "$products/DevStack"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources" "$application/Contents/Library/LaunchServices" "$application/Contents/Library/LaunchDaemons"
cp "$repository_root/Packaging/Info.plist" "$application/Contents/Info.plist"
cp "$products/DevStack" "$application/Contents/MacOS/DevStack"
cp "$products/DevStackPrivilegedHelper" "$application/Contents/Library/LaunchServices/DevStackPrivilegedHelper"
cp "$repository_root/Sources/DevStackApp/Resources/app.devstack.desktop.helper.plist" "$application/Contents/Library/LaunchDaemons/"
cp "$repository_root/Sources/DevStackApp/Resources/DevStack.icns" "$application/Contents/Resources/"
for resource_bundle in "$products"/*.bundle; do
    [[ ! -d "$resource_bundle" ]] || ditto "$resource_bundle" "$application/Contents/Resources/$(basename "$resource_bundle")"
done
"$repository_root/scripts/embed-sparkle.sh" "$application" "$products" -
/usr/bin/codesign --force --entitlements "$repository_root/Packaging/Helper.entitlements" --sign - "$application/Contents/Library/LaunchServices/DevStackPrivilegedHelper"
/usr/bin/codesign --force --entitlements "$repository_root/Packaging/DevStack.entitlements" --sign - "$application"
/usr/bin/codesign --verify --deep --strict "$application"
mkdir -p "$preview_root/previous"
if [[ -d "$preview_root/DevStack.app" ]]; then
    mv "$preview_root/DevStack.app" "$preview_root/previous/DevStack-$build_stamp.app"
fi
mv "$application" "$preview_root/DevStack.app"
application="$preview_root/DevStack.app"
echo "Preview application: $application"

if [[ "${DEVSTACK_INSTALL_PREVIEW:-0}" == "1" ]]; then
    destination="/Applications/DevStack.app"
    [[ -w /Applications ]] || { echo "Applications is not writable." >&2; exit 73; }
    # Never clobber a Developer ID signed install with an ad-hoc preview:
    # that silently breaks the helper (ad-hoc has no Team ID, fail-closed).
    if [[ -d "$destination" ]] && /usr/bin/codesign -dv "$destination" 2>&1 | /usr/bin/grep -q "TeamIdentifier="; then
        team=$(/usr/bin/codesign -dv "$destination" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | head -n 1)
        if [[ -n "$team" && "$team" != "not set" ]]; then
            echo "Refusing: $destination is signed (Team $team). Installing an ad-hoc preview over it would break the helper." >&2
            echo "Quit preview, open /Applications/DevStack.app for helper work, or delete the signed install first if you really mean it." >&2
            exit 74
        fi
    fi
    installed_stage="/Applications/.DevStack-$build_stamp.app"
    ditto "$application" "$installed_stage"
    /usr/bin/codesign --verify --deep --strict "$installed_stage"
    if [[ -d "$destination" ]]; then
        mv "$destination" "$preview_root/previous/Installed-DevStack-$build_stamp.app"
    fi
    mv "$installed_stage" "$destination"
    echo "Installed preview (ad-hoc, helper unavailable): $destination" >&2
    echo "For helper work use the Developer ID signed release in /Applications/DevStack.app." >&2
fi
echo "Preview is ad-hoc signed: helper stays unavailable by design. Launch /Applications/DevStack.app for helper work." >&2
