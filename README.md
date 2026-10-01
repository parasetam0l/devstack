# DevStack

A local development stack for macOS: Apache/Nginx, PHP 8.4/8.5 (optionally
7.4), MySQL 8.4 (optionally 5.7), PostgreSQL 18, Mailpit,
phpMyAdmin/Adminer, Composer, ImageMagick, TLS certificates and a privileged
helper for ports 80/443 and local DNS. Everything runs offline from runtimes
bundled in the app; nothing is downloaded on the user's Mac.

## Build

Requires an Apple Silicon Mac running macOS 27 with Xcode 26.

```sh
swift build --jobs 2
"$(swift build --show-bin-path)/DevStackCoreChecks"
```

Run a local preview app (ad-hoc signed, helper unavailable):

```sh
scripts/build-preview.sh
```

Produce the signed, notarized DMG (runtime payload must exist at
`.build/Runtimes`):

```sh
DEVSTACK_INCLUDE_LEGACY=1 \
DEVSTACK_SIGNING_IDENTITY="Developer ID Application: ..." \
DEVSTACK_NOTARY_PROFILE=DevStack \
    scripts/package-release.sh
```

## Documentation

- [Documentation/Building.md](Documentation/Building.md) — compile, preview,
  signed DMG, build directory layout and cleanup.
- [Documentation/RuntimeBuild.md](Documentation/RuntimeBuild.md) — bundled
  runtime payload pipeline.
- [Documentation/HANDOVER.md](Documentation/HANDOVER.md) — verification state
  and known limitations.
- `scripts/clean-build.sh` — prune generated state under `.build`.
