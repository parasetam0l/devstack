#!/bin/bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
preview_root="$repository_root/.build/preview"
application="$preview_root/DevStack.app"
# UI previews use the existing default runtime payloads. Legacy gates belong to release packaging.
runtime_root="${DEVSTACK_PREVIEW_RUNTIME_ROOT:-$repository_root/.build/release/DevStack.app/Contents/Resources/Runtimes}"
[[ -d "$runtime_root" ]] || runtime_root="$repository_root/.build/Runtimes"
cd "$repository_root"
swift build --build-system native --jobs "${DEVSTACK_BUILD_JOBS:-4}"
products="$(swift build --build-system native --show-bin-path)"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources/Runtimes" "$application/Contents/Library/LaunchServices" "$application/Contents/Library/LaunchDaemons"
cp "$repository_root/Packaging/Info.plist" "$application/Contents/Info.plist"
cp "$products/DevStack" "$application/Contents/MacOS/DevStack"
cp "$products/DevStackPrivilegedHelper" "$application/Contents/Library/LaunchServices/DevStackPrivilegedHelper"
cp "$repository_root/Sources/DevStackApp/Resources/app.devstack.desktop.helper.plist" "$application/Contents/Library/LaunchDaemons/"
cp "$repository_root/Sources/DevStackApp/Resources/DevStack.icns" "$application/Contents/Resources/"
for resource_bundle in "$products"/*.bundle; do
    [[ ! -d "$resource_bundle" ]] || ditto "$resource_bundle" "$application/Contents/Resources/$(basename "$resource_bundle")"
done
for id in apache-2.4 php-8.5 mysql-8.4 openssl-3.5 mailpit-1.31.1 phpmyadmin-5.2.3 composer-2.10.3 imagemagick-7.1; do
    if [[ -d "$runtime_root/$id" && ! -d "$application/Contents/Resources/Runtimes/$id" ]]; then
        cp -cR "$runtime_root/$id" "$application/Contents/Resources/Runtimes/$id"
    fi
done
/usr/bin/codesign --force --entitlements "$repository_root/Packaging/Helper.entitlements" --sign - "$application/Contents/Library/LaunchServices/DevStackPrivilegedHelper"
/usr/bin/codesign --force --entitlements "$repository_root/Packaging/DevStack.entitlements" --sign - "$application"
/usr/bin/codesign --verify --deep --strict "$application"
echo "Preview application: $application"
