# Building and releasing DevStack

This is the end-to-end guide for compiling the app and producing the signed,
notarized DMG on a Mac. Releases are normally made by GitHub Actions instead
(see [docs/RELEASING.md](../docs/RELEASING.md)). The runtimes are built,
signed and published separately by
[devstack-runtimes](https://github.com/parasetam0l/devstack-runtimes); this
repository only pins them.

## Requirements

- Apple Silicon Mac with full Xcode 27 selected (`xcode-select -p` should
  print the Xcode developer directory). The app runs on macOS 15 and later.
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

Run every command from the repository root.

```sh
swift build --jobs 2                  # debug
swift build -c release --jobs 2       # release
swift build --show-bin-path           # directory holding the built executables
```

`.build/debug` and `.build/release` are symlinks to the SwiftPM product
directories under `.build/out/Products`.

Run the checks:

```sh
"$(swift build --show-bin-path)/DevStackCoreChecks"
```

`DevStackRuntimeChecks` starts every service from a folder of installed
runtimes, with its own scratch data, and exercises them end to end. Stop your
stack first: it uses ports 3306, 5432, 8080, 8443 and 8025.

```sh
"$(swift build --show-bin-path)/DevStackRuntimeChecks" ~/Library/Application\ Support/DevStack/Runtimes
```

## Local preview app

`scripts/build-preview.sh` assembles a runnable `DevStack.app` from the debug
build. Like a release, it holds no runtimes: it uses the packs installed from
its Runtimes page. It is ad-hoc signed, so the privileged helper stays
unavailable by design.

```sh
scripts/build-preview.sh
DEVSTACK_INSTALL_PREVIEW=1 scripts/build-preview.sh   # also install to /Applications
```

The installer refuses to replace a Developer ID signed install, and refuses to
replace a running app.

## Signed and notarized DMG

```sh
DEVSTACK_SIGNING_IDENTITY="Developer ID Application: Serkan KAYA (P7V7795SS9)" \
DEVSTACK_NOTARY_PROFILE=DevStack \
scripts/package-release.sh
```

Long runs are easier to follow through a log file:

```sh
mkdir -p .build/logs
LOG=".build/logs/package-$(date +%Y%m%d-%H%M%S).log"
set -o pipefail
DEVSTACK_SIGNING_IDENTITY="Developer ID Application: Serkan KAYA (P7V7795SS9)" \
DEVSTACK_NOTARY_PROFILE=DevStack \
    scripts/package-release.sh 2>&1 | tee "$LOG"
ln -sf "$LOG" .build/logs/package-latest.log
tail -f .build/logs/package-latest.log
```

The version comes from `Packaging/Info.plist`
(`CFBundleShortVersionString` and `CFBundleVersion`); the release name is
`DevStack-<version>-arm64.dmg`. Without a signing identity the script makes an
ad-hoc development image, `DevStack-<version>-arm64-adhoc.dmg`, under
`.build/release/adhoc`, so it never replaces a notarized release.

### What the script does

1. Validates Apple Silicon and that runtime packs are pinned, then builds the
   release binaries and runs `DevStackCoreChecks`.
2. Stages `DevStack.app`: Info.plist, icon, privileged helper, resources, the
   licence and Sparkle's notice. Runtimes are not bundled; each pack carries
   its own notices, sources and SBOM.
3. Embeds and signs Sparkle (`scripts/embed-sparkle.sh`), then signs the helper
   and the app with the hardened runtime and a secure timestamp, and verifies
   that the app and helper Team IDs match.
4. With a notary profile: notarizes and staples the app and assesses it with
   Gatekeeper, so the copy inside the image carries its own ticket.
5. Builds the branded DMG layout (background plus a `.DS_Store` written directly,
   no Finder automation) and signs the image.
6. With a notary profile: notarizes and staples the DMG and assesses it. Every
   submission must come back Accepted.
7. Moves the previous same-named artifacts into `<release root>/previous/<stamp>/`.

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEVSTACK_SIGNING_IDENTITY` | `-` (ad-hoc) | Developer ID identity used for the helper, the app and the DMG. |
| `DEVSTACK_NOTARY_PROFILE` | unset | `notarytool` keychain profile. Unset signs but does not notarize. |
| `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, `TEAM_ID` | unset | Notarize with an Apple ID and app-specific password instead (as CI does). |
| `DEVSTACK_BUILD_JOBS` | `2` | Swift build jobs. |
| `DEVSTACK_RELEASE_ROOT` | `.build/release` | Output directory for the DMG and app. |

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

The first launch downloads the runtimes and needs the helper to be approved
once in System Settings → General → Login Items & Extensions; the setup wizard
walks through both.

## Runtime packs

Runtimes are built and published by
[devstack-runtimes](https://github.com/parasetam0l/devstack-runtimes), one
signed, notarized pack per runtime; its `docs/BUILDING.md` covers building and
changing them. DevStack installs them during setup and from its Runtimes page
into `~/Library/Application Support/DevStack/Runtimes`.

Each DevStack version pins the exact packs it installs in
`Sources/DevStackApp/Resources/runtime-packs.json`. To pin a newly
published pack (it is downloaded and checked against its `pack.json` first):

```sh
scripts/pin-runtime.sh php-8.5-8.5.11-r1
```

Before a release, check that every runtime is pinned and every pinned pack is
still available and intact:

```sh
scripts/pin-runtime.sh --check
```

To try packs before they are published, build them in devstack-runtimes and
point a debug build at a local catalog whose URLs are `file:` URLs:

```sh
DEVSTACK_RUNTIME_CATALOG=/path/to/runtime-packs.json "$(swift build --show-bin-path)/DevStack"
```

A signed DevStack installs only packs whose binaries carry its own Team ID;
a debug build accepts any valid signature.

## Build directory

| Path | Contents | Default cleanup |
| --- | --- | --- |
| `.build/out` | SwiftPM/Xcode build state and products; release DMGs live in `out/Products/Release`, ad-hoc images in `out/Products/Release/adhoc`. | newest release DMG kept; ad-hoc images removed (`--deep` also prunes caches) |
| `.build/artifacts` | Binary packages SwiftPM downloaded, among them Sparkle and its tools. | kept |
| `.build/logs` | Packaging history; `package-latest.log` points at the last run. | old logs removed |

`scripts/clean-build.sh` prunes generated state without touching sources or
user data (it never goes near `~/Library/Application Support/DevStack`):

```sh
scripts/clean-build.sh          # release history, staging, scratch trees, stale logs
scripts/clean-build.sh --deep   # also drop SwiftPM caches and runtime builds from before packs
scripts/clean-build.sh --all    # remove .build entirely
```

## Troubleshooting

- `hdiutil` deprecation warnings during DMG creation are cosmetic; the layout
  still builds correctly.
- `No runtime packs are pinned` — pin the published packs first
  (`scripts/pin-runtime.sh`).
- Notarization rejected: check `xcrun notarytool history --keychain-profile DevStack`
  and the submission log; common causes are a missing secure timestamp,
  unsigned nested binaries, or a stale profile.
- Helper reports unauthorized requests: the app and helper must share one Team
  ID. `package-release.sh` fails early on a mismatch; an ad-hoc preview build
  cannot use the helper by design.
