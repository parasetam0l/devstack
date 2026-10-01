# Building and releasing DevStack

This is the current, end-to-end guide for compiling the app and producing the
signed, notarized DMG. The bundled runtime payload has its own pipeline; see
[RuntimeBuild.md](RuntimeBuild.md) for the details referenced below.

## Requirements

- Apple Silicon Mac running macOS 27, with full Xcode 26 selected
  (`xcode-select -p` should print the Xcode developer directory).
- The runtime payload at `.build/Runtimes` (see
  [Building the runtime payload](#building-the-runtime-payload)).
- For a distributable image: a **Developer ID Application** certificate in the
  login keychain and a `notarytool` keychain profile.

Check the signing identity:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Create the notarization profile once (store an app-specific password, not your
Apple ID password):

```sh
xcrun notarytool store-credentials DevStack \
    --apple-id "you@example.com" \
    --team-id "P7V7795SS9" \
    --password "<app-specific-password>"
```

## Compile

```sh
cd /Users/serkan/Desktop/localhost

swift build --jobs 2                  # debug
swift build -c release --jobs 2       # release
swift build --show-bin-path           # directory holding the built executables
```

`.build/debug` and `.build/release` are symlinks to the SwiftPM product
directories under `.build/out/Products`.

Run the checks:

```sh
"$(swift build --show-bin-path)/DevStackCoreChecks"
# Stop the stack first: the runtime check uses ports 3306, 5432, 8080, 8443, 8025.
/usr/bin/python3 scripts/run-bounded-check.py --seconds 300 \
    -- "$(swift build --show-bin-path)/DevStackRuntimeChecks" .build/Runtimes
```

## Local preview app

`scripts/build-preview.sh` assembles a runnable `DevStack.app` from the debug
build and the `.build/Runtimes` payload. It is ad-hoc signed, so the privileged
helper stays unavailable by design.

```sh
scripts/build-preview.sh
DEVSTACK_INSTALL_PREVIEW=1 scripts/build-preview.sh   # also install to /Applications
```

The installer refuses to replace a Developer ID signed install, and refuses to
replace a running app.

## Signed and notarized DMG

```sh
DEVSTACK_INCLUDE_LEGACY=1 \
DEVSTACK_SIGNING_IDENTITY="Developer ID Application: Serkan KAYA (P7V7795SS9)" \
DEVSTACK_NOTARY_PROFILE=DevStack \
scripts/package-release.sh
```

Long runs are easier to follow through a log file:

```sh
mkdir -p .build/logs
LOG=".build/logs/package-$(date +%Y%m%d-%H%M%S).log"
set -o pipefail
DEVSTACK_INCLUDE_LEGACY=1 \
DEVSTACK_SIGNING_IDENTITY="Developer ID Application: Serkan KAYA (P7V7795SS9)" \
DEVSTACK_NOTARY_PROFILE=DevStack \
    scripts/package-release.sh 2>&1 | tee "$LOG"
ln -sf "$LOG" .build/logs/package-latest.log
tail -f .build/logs/package-latest.log
```

The version comes from `Packaging/Info.plist`
(`CFBundleShortVersionString` and `CFBundleVersion`); the release name is
`DevStack-<version>-arm64.dmg`.

### What the script does

1. Validates Apple Silicon and that `.build/Runtimes` exists, then builds the
   release binaries and runs `DevStackCoreChecks`.
2. Stages `DevStack.app`: Info.plist, icon, privileged helper, selected
   runtimes, third-party notices, SBOM and corresponding sources.
3. Audits the payload (`scripts/audit-runtime.sh`): ARM64 only, signed Mach-O,
   no package-manager paths, no build-machine paths, no forbidden RPATHs.
4. Signs every bundled Mach-O, the helper and the app with the hardened runtime
   and a secure timestamp; verifies the app and helper Team IDs match.
5. Builds the branded DMG layout (background plus a `.DS_Store` written directly,
   no Finder automation) and signs the image.
6. Submits to the Apple notary service, waits, staples the app and the DMG, and
   runs the Gatekeeper assessment.
7. Moves the previous same-named artifacts into
   `.build/out/Products/Release/previous/<stamp>/`.

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEVSTACK_SIGNING_IDENTITY` | `-` (ad-hoc) | Developer ID identity used for nested code, app and DMG. |
| `DEVSTACK_NOTARY_PROFILE` | unset | `notarytool` keychain profile. Unset signs but does not notarize. |
| `DEVSTACK_INCLUDE_LEGACY` | `0` | Include PHP 7.4 and MySQL 5.7 when their gates pass. |
| `DEVSTACK_BUILD_JOBS` | `2` | Swift build jobs. |
| `DEVSTACK_RUNTIME_OUTPUT` | `.build/Runtimes` | Runtime payload directory. |
| `DEVSTACK_RELEASE_ROOT` | `.build/release` | Output directory for the DMG and app. |
| `DEVSTACK_SOURCE_CACHE` | `.build/runtime-cache` | Source archives copied into `CorrespondingSources`. |

### Outputs and verification

```sh
xcrun stapler validate .build/release/DevStack-*.dmg
spctl --assess --type open --context context:primary-signature -v .build/release/DevStack-*.dmg

hdiutil attach .build/release/DevStack-*.dmg -nobrowse -readonly -mountpoint /tmp/devstack-dmg
rm -rf /Applications/DevStack.app
ditto /tmp/devstack-dmg/DevStack.app /Applications/DevStack.app
hdiutil detach /tmp/devstack-dmg
open -a /Applications/DevStack.app
```

The first launch needs the helper to be approved once in System Settings →
General → Login Items & Extensions; the setup wizard walks through it.

## Building the runtime payload

The payload is the signed `Contents/Resources/Runtimes` tree copied into the
app. It never downloads or builds anything on the user's Mac. On the release
host:

```sh
scripts/fetch-build-tools.sh
export PATH="$PWD/.build/build-tools/bin:$PATH"
scripts/verify-sources.sh
scripts/build-dependencies.sh all
scripts/build-runtimes.sh all
```

`runtime-lock.json` is the source of truth: every artifact is HTTPS-only and
SHA-256 checked, and every runtime is audited before packaging. PHP 7.4 and
MySQL 5.7 enter a release only with `DEVSTACK_INCLUDE_LEGACY=1` and a passing
gate (`scripts/gates/php74.sh`, `scripts/gates/mysql57.sh`). Read
[RuntimeBuild.md](RuntimeBuild.md) before changing the payload.

## Build directory

| Path | Contents | Default cleanup |
| --- | --- | --- |
| `.build/Runtimes` | Signed runtime payload; required by preview and release. | kept |
| `.build/runtime-cache` | Pinned source archives; also shipped as `CorrespondingSources`. | kept |
| `.build/runtime-dependencies` | Rebuilt dependency prefixes for runtime builds. | kept (`--deep` removes) |
| `.build/build-tools`, `build-tools-cache` | Pinned host toolchain and its archives. | kept (`--deep` removes) |
| `.build/runtime-work`, `runtime-test-fixtures`, `build-tools-work` | Scratch build trees. | removed |
| `.build/out` | SwiftPM/Xcode build state and products; release DMGs live in `out/Products/Release`. | caches kept (`--deep` prunes) |
| `.build/logs` | Packaging history; `package-latest.log` points at the last run. | old logs removed |

`scripts/clean-build.sh` prunes generated state without touching sources or
user data (it never goes near `~/Library/Application Support/DevStack`):

```sh
scripts/clean-build.sh          # release history, staging, scratch trees, stale logs
scripts/clean-build.sh --deep   # also drop rebuild caches; re-run verify-sources.sh before packaging
scripts/clean-build.sh --all    # remove .build entirely; runtimes must be rebuilt
```

On the current development machine the default mode reduced `.build` from
44.3 GiB to 3.7 GiB.

## Troubleshooting

- `hdiutil` deprecation warnings during DMG creation are cosmetic; the layout
  still builds correctly.
- `Runtime payload is missing: .../Runtimes` — build the payload first.
- Notarization rejected: check `xcrun notarytool history --keychain-profile DevStack`
  and the submission log; common causes are a missing secure timestamp,
  unsigned nested binaries, or a stale profile.
- Helper reports unauthorized requests: the app and helper must share one Team
  ID. `package-release.sh` fails early on a mismatch; an ad-hoc preview build
  cannot use the helper by design.
