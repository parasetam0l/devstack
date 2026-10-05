# DevStack

A local development stack for macOS: Apache/Nginx, PHP 8.4/8.5 (optionally
7.4), MySQL 8.4 (optionally 5.7), PostgreSQL 18, Mailpit,
phpMyAdmin/Adminer, Composer, ImageMagick, TLS certificates and a privileged
helper for ports 80/443 and local DNS. The setup wizard downloads the
runtimes you choose, signed and notarized packs built from source by
[devstack-runtimes](https://github.com/parasetam0l/devstack-runtimes), and
verifies each one before installing it; after that everything runs offline.

## Build

Requires an Apple Silicon Mac with Xcode 27. DevStack and its runtimes run on
macOS 15 and later.

```sh
swift build --jobs 2
"$(swift build --show-bin-path)/DevStackCoreChecks"
```

Run a local preview app (ad-hoc signed, helper unavailable):

```sh
scripts/build-preview.sh
```

Produce the signed, notarized DMG locally (releases normally come from
GitHub Actions; see docs/RELEASING.md):

```sh
DEVSTACK_SIGNING_IDENTITY="Developer ID Application: ..." \
DEVSTACK_NOTARY_PROFILE=DevStack \
    scripts/package-release.sh
```

## Documentation

- [Documentation/Building.md](Documentation/Building.md) — compile, preview,
  signed DMG, runtime pack pinning, build directory layout and cleanup.
- [Documentation/Importing.md](Documentation/Importing.md) — importing
  projects and databases from XAMPP, and adding other sources.
- [devstack-runtimes](https://github.com/parasetam0l/devstack-runtimes) —
  how the runtime packs are built, tested and published.
- [docs/RELEASING.md](docs/RELEASING.md) — signed releases from GitHub
  Actions, Sparkle updates, one-time setup.
- `scripts/clean-build.sh` — prune generated state under `.build`.
