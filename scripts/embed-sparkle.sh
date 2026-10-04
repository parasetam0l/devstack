#!/bin/bash
#
# Embeds Sparkle.framework from SwiftPM's products into an assembled
# DevStack.app and signs its helpers. Sparkle ships them ad-hoc signed;
# notarization needs every executable signed with Developer ID, the hardened
# runtime and a secure timestamp. Inner code first, the framework last, as in
# SemiVPN's and LocalDesktop's sparkle-sign.sh. Run it before signing the app.
#
# Usage: scripts/embed-sparkle.sh APPLICATION PRODUCTS_DIRECTORY IDENTITY
#   IDENTITY "-" signs ad-hoc for development builds.

set -euo pipefail

application="${1:?usage: embed-sparkle.sh APPLICATION PRODUCTS_DIRECTORY IDENTITY}"
products="${2:?}"
identity="${3:?}"
executable="$application/Contents/MacOS/DevStack"
framework="$application/Contents/Frameworks/Sparkle.framework"

[[ -d "$products/Sparkle.framework" ]] || { echo "Sparkle.framework is missing from $products" >&2; exit 66; }
mkdir -p "$application/Contents/Frameworks"
rm -rf "$framework"
/usr/bin/ditto "$products/Sparkle.framework" "$framework"

# The app finds Sparkle in Contents/Frameworks. Build-machine search paths
# (SwiftPM's framework folder, the Xcode toolchain) never ship; nothing the
# app links lives there.
rpaths="$(/usr/bin/otool -l "$executable" | /usr/bin/awk '/LC_RPATH/{getline; getline; print $2}')"
while IFS= read -r rpath; do
    if [[ "$rpath" == /* && "$rpath" != /usr/lib/swift ]]; then
        /usr/bin/install_name_tool -delete_rpath "$rpath" "$executable"
    fi
done <<< "$rpaths"
if ! printf '%s\n' "$rpaths" | /usr/bin/grep -qx '@executable_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$executable"
fi

options=(--force --options runtime --timestamp --sign "$identity")
[[ "$identity" != "-" ]] || options=(--force --timestamp=none --sign -)
helpers="$framework/Versions/B"
/usr/bin/codesign "${options[@]}" "$helpers/XPCServices/Installer.xpc"
/usr/bin/codesign "${options[@]}" --preserve-metadata=entitlements "$helpers/XPCServices/Downloader.xpc"
/usr/bin/codesign "${options[@]}" "$helpers/Autoupdate"
/usr/bin/codesign "${options[@]}" "$helpers/Updater.app"
/usr/bin/codesign "${options[@]}" "$framework"
