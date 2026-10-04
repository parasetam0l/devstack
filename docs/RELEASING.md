# Releasing DevStack

Releases are built by the **Release** GitHub Actions workflow
(`.github/workflows/release.yml`). It runs only when started by hand. It signs
DevStack with a Developer ID certificate, has Apple notarize it, and creates a
**draft** GitHub release with `DevStack-<version>-arm64.dmg`. The DMG holds
the app alone, about 8 MB. Runtimes come from the packs pinned in
`Sources/DevStackApp/Resources/runtime-packs.json`, which the setup wizard and
the Runtimes page download and verify.

Publishing the draft starts the **Appcast** workflow, which signs the DMG for
Sparkle and attaches `appcast.xml`. Installed copies then offer the update.

The repository is public, so the macOS runner minutes are free.

## One-time setup

The certificate and the notarization password are the same as for SemiVPN and
LocalDesktop (see their `docs/RELEASING.md` for creating them). Team:
`P7V7795SS9`.

### Repository secrets

In this repository's folder. `gh secret set NAME` without a value asks for it,
so it stays out of your shell history:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
```

```sh
gh secret set DEVELOPER_ID_P12_PASSWORD
```

```sh
gh secret set NOTARY_APPLE_ID
```

```sh
gh secret set NOTARY_PASSWORD
```

Then delete the exported `DeveloperID.p12`; the certificate stays in your
keychain.

### Update signing key (Sparkle)

Installed copies check `appcast.xml` on the latest published release once a
day. They install an update only if its EdDSA signature matches the public key
built into the app (`SUPublicEDKey` in `Packaging/Info.plist`). Create the key
pair once, after a `swift build` (SwiftPM downloads Sparkle's tools with the
package):

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account devstack
```

It saves the private key in your login keychain and prints the public key.
Keep the private key: if it is lost, installed copies can't update. Put the
public key in `Packaging/Info.plist` as `SUPublicEDKey`. Then give the private
key to the Appcast workflow and delete the exported file:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account devstack -x sparkle-private.key
```

```sh
gh secret set SPARKLE_PRIVATE_KEY < sparkle-private.key
```

```sh
rm sparkle-private.key
```

Builds made before `SUPublicEDKey` is set don't check for updates.

## Making a release

1. Make sure the runtime packs you want are pinned
   (`scripts/pin-runtime.sh <pack-name>`; see `Documentation/Building.md`).
   The workflow stops while any runtime but the legacy PHP 7.4 and MySQL 5.7
   is unpinned. It also re-downloads every pinned pack and checks it against
   its hash.
2. GitHub → **Actions** → **Release** → **Run workflow**, enter the version
   (e.g. `0.4.0`) and run it. It takes about 20–40 minutes, most of it
   waiting for Apple's notary service, which runs twice: once for the app,
   once for the DMG.
3. GitHub → **Releases**: edit the draft's notes and **Publish** it.
   Publishing creates the `v<version>` tag.
4. Publishing starts the **Appcast** workflow (about 2 minutes). It signs the
   DMG with the update key, checks the signature against the key in the app,
   and attaches `appcast.xml`. To redo it, for example after editing the
   notes, run Actions → **Appcast** → Run workflow with the tag.

## What users see

- **New installs:** the setup wizard downloads the runtimes the stack needs
  and the optional ones they pick, then sets up the helper and the
  certificate.
- **Updates:** Sparkle offers the new version and installs it after asking.
  Services keep running across the relaunch, because runtimes live outside
  the app, and the new version adopts them. If the helper's build changed,
  macOS may ask for its approval again.
