# Sourced by the build scripts: linker options for `swift build`.
#
# SwiftPM links through clang with --sysroot rather than -isysroot, so clang
# never reads the SDK's version and records the deployment target in its
# place (sdk 15.0). macOS 26 and later then run DevStack in the compatibility
# look, without Liquid Glass. Record the SDK it is really built with.
minimum_macos="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$repository_root/Packaging/Info.plist")"
sdk_version="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
swift_link_options=(-Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_macos" -Xlinker "$sdk_version")

# Fails unless the executable records the SDK it was built with.
check_sdk_version() {
    local recorded
    recorded="$(/usr/bin/otool -l "$1" | /usr/bin/awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "sdk" { print $2; exit }')"
    if [[ "$recorded" != "$sdk_version" ]]; then
        echo "$(basename "$1") records SDK ${recorded:-none}, not $sdk_version: macOS would draw it in the compatibility look." >&2
        return 1
    fi
}
