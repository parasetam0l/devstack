#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="${DEVSTACK_RUNTIME_OUTPUT:-$repository_root/.build/Runtimes}"
release_root="${DEVSTACK_RELEASE_ROOT:-$repository_root/.build/release}"
build_stamp="$(date +%Y%m%d-%H%M%S)-$$"
identity="${DEVSTACK_SIGNING_IDENTITY:--}"
release_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$repository_root/Packaging/Info.plist")"
release_name="DevStack-$release_version-arm64.dmg"
# Ad-hoc output lives apart from Developer ID releases, so a development run
# never rotates a notarized app or image of the same version away.
if [[ "$identity" == "-" ]]; then
    release_root="$release_root/adhoc"
    release_name="DevStack-$release_version-arm64-adhoc.dmg"
fi
staging_root="$release_root/staging/$build_stamp"
application="$staging_root/DevStack.app"

[[ "$(uname -m)" == "arm64" ]] || { echo "Release packaging requires Apple Silicon." >&2; exit 69; }
[[ -d "$runtime_root" ]] || { echo "Runtime payload is missing: $runtime_root" >&2; exit 66; }
if [[ "$identity" == "-" && -n "${DEVSTACK_NOTARY_PROFILE:-}" ]]; then
    echo "Notarization needs a Developer ID identity; set DEVSTACK_SIGNING_IDENTITY." >&2
    exit 64
fi

# The layout image is attached read-write while the DMG is assembled; never
# leave it mounted when a later step fails.
layout_mount=""
detach_layout_image() {
    if [[ -n "$layout_mount" ]]; then /usr/bin/hdiutil detach "$layout_mount" -force >/dev/null 2>&1 || true; fi
}
trap detach_layout_image EXIT

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

# Every shipped component needs its notices, and the copyleft ones (MySQL,
# phpMyAdmin, gettext and others) need their exact sources. Developer ID
# releases stop when either is missing; ad-hoc development builds only warn.
if ! /usr/bin/python3 "$repository_root/scripts/collect-licenses.py" check "$repository_root/ThirdPartyNotices" "${runtime_ids[@]}"; then
    if [[ "$identity" != "-" ]]; then
        echo "Run scripts/verify-sources.sh, then scripts/collect-licenses.py notices ThirdPartyNotices." >&2
        exit 72
    fi
    echo "warning: this ad-hoc build ships incomplete licence notices or sources." >&2
fi
if [[ -d "$repository_root/ThirdPartyNotices" ]]; then cp -R "$repository_root/ThirdPartyNotices" "$application/Contents/Resources/ThirdPartyNotices"; fi
/usr/bin/python3 "$repository_root/scripts/collect-licenses.py" sources "$application/Contents/Resources/CorrespondingSources" "${runtime_ids[@]}"
mkdir -p "$application/Contents/Resources/CorrespondingSources/DevStackPatches"
cp "$repository_root/scripts/prepare-imagemagick.py" "$repository_root/scripts/configure-phpmyadmin.py" "$application/Contents/Resources/CorrespondingSources/DevStackPatches/"
cp "$repository_root/LICENSE" "$application/Contents/Resources/LICENSE"

signing_options=(--options runtime --timestamp)
if [[ "$identity" == "-" ]]; then
    signing_options=(--timestamp=none)
    echo "No Developer ID identity configured: producing an ad-hoc development build." >&2
fi
# Listed into a file first: a failing lister inside process substitution would
# go unnoticed by set -e and leave the payload unsigned.
mach_o_list="$staging_root/mach-o-files"
/usr/bin/python3 "$repository_root/scripts/mach-o-files.py" "$application/Contents/Resources/Runtimes" > "$mach_o_list"
while IFS= read -r -d '' binary; do
    if /usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign --force "${signing_options[@]}" --sign "$identity" "$binary"
    fi
done < "$mach_o_list"
rm -f "$mach_o_list"
# Signing rewrites every Mach-O, so the SBOM hashes the signed payload.
"$repository_root/scripts/generate-sbom.py" "$application/Contents/Resources/Runtimes" "$application/Contents/Resources/SBOM/runtime-sbom.cdx.json"

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

# Submits an artifact and waits for Apple's verdict. Anything but Accepted
# stops the release. The --wait client can time out on a slow connection even
# though the submission finishes, so the submission id is polled instead of
# losing the work.
notarize() {
    local artifact="$1" submit_output submission_id submission_status=""
    if submit_output="$(xcrun notarytool submit "$artifact" --keychain-profile "$DEVSTACK_NOTARY_PROFILE" --wait 2>&1)"; then
        printf '%s\n' "$submit_output"
        submission_status="$(printf '%s\n' "$submit_output" | /usr/bin/sed -n 's/^[[:space:]]*status: //p' | /usr/bin/tail -n 1)"
    else
        printf '%s\n' "$submit_output" >&2
        echo "Waiting for the submission after a client timeout..." >&2
    fi
    submission_id="$(printf '%s\n' "$submit_output" | /usr/bin/sed -n 's/^[[:space:]]*id: //p' | /usr/bin/head -n 1)"
    [[ -n "$submission_id" ]] || { echo "Notarization failed without a submission id." >&2; exit 71; }
    for _ in $(seq 1 80); do
        case "$submission_status" in
            Accepted) return 0 ;;
            Invalid|Rejected)
                xcrun notarytool log "$submission_id" --keychain-profile "$DEVSTACK_NOTARY_PROFILE" >&2 || true
                echo "Notarization rejected: $submission_id" >&2
                exit 71
                ;;
        esac
        sleep 15
        submission_status="$(xcrun notarytool info "$submission_id" --keychain-profile "$DEVSTACK_NOTARY_PROFILE" 2>/dev/null | /usr/bin/awk '/status:/ {print $2}' | /usr/bin/head -n 1)"
    done
    echo "Notarization did not finish: $submission_id" >&2
    exit 71
}

# Notarize and staple the app before it goes into the image, so the copy users
# drag to Applications carries its own ticket and passes Gatekeeper offline.
if [[ -n "${DEVSTACK_NOTARY_PROFILE:-}" ]]; then
    app_archive="$staging_root/DevStack-notarization.zip"
    /usr/bin/ditto -c -k --keepParent "$application" "$app_archive"
    notarize "$app_archive"
    rm -f "$app_archive"
    xcrun stapler staple "$application"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$application"
fi

dmg="$staging_root/$release_name"
dmg_root="$staging_root/dmg-root"
rw_dmg="$staging_root/DevStack-layout.dmg"
mount_point="$staging_root/dmg-mount"
rm -rf "$dmg_root" "$rw_dmg" "$mount_point" "$dmg"
mkdir -p "$dmg_root" "$mount_point"
cp -cR "$application" "$dmg_root/DevStack.app"
ln -s /Applications "$dmg_root/Applications"

# Lay the installer window out on a read-write image, then compress it: the app
# and the Applications drop target sit at the arrow of a branded background,
# with large icons. The layout is written straight into .DS_Store so packaging
# never depends on Finder automation.
/usr/bin/hdiutil create -srcfolder "$dmg_root" -volname DevStack -fs HFS+ -format UDRW -ov "$rw_dmg" >/dev/null
/usr/bin/hdiutil attach "$rw_dmg" -nobrowse -readwrite -mountpoint "$mount_point" >/dev/null
layout_mount="$mount_point"
/usr/bin/python3 "$repository_root/scripts/write-dmg-dsstore.py" \
    "$mount_point" "$repository_root/Packaging/dmg-background.tiff" \
    "240,180,660,420" 128 13 "DevStack.app:165:200" "Applications:495:200"
/usr/bin/hdiutil detach "$mount_point" >/dev/null
layout_mount=""
/usr/bin/hdiutil convert "$rw_dmg" -format UDZO -o "$dmg" >/dev/null
rm -rf "$dmg_root" "$rw_dmg" "$mount_point"
/usr/bin/codesign --force "${signing_options[@]}" --sign "$identity" "$dmg"

if [[ -n "${DEVSTACK_NOTARY_PROFILE:-}" ]]; then
    notarize "$dmg"
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
