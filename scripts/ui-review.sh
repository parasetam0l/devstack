#!/bin/bash
# Runs the app in UI review mode (see Sources/DevStackApp/UIReview.swift),
# for example: scripts/ui-review.sh --ui-review sites --populated --snapshot DIR
# It builds with the real SDK version first: a plain `swift build` makes
# macOS draw the compatibility look, without Liquid Glass.
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"
source "$repository_root/scripts/swift-link-options.sh"
swift build --product DevStack --jobs "${DEVSTACK_BUILD_JOBS:-2}" "${swift_link_options[@]}" >&2
products="$(swift build --show-bin-path)"
check_sdk_version "$products/DevStack"
exec "$products/DevStack" "$@"
