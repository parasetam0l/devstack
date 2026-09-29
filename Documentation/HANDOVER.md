# DevStack progress handover

Verified on 29 September 2026, Europe/Istanbul, from the repository, local artifacts, build logs, and executable checks.

## Current checkpoint

The application source and runtime build pipeline are implemented, and a local preview app and DMG exist. This is not yet a distributable, fully tested offline release.

- Workspace: `/Users/serkan/Desktop/localhost`
- Branch: `main`
- Implementation checkpoint before this document: `ebd7add` — `fix: compile legacy PHP intl as C++17 for ICU 78`
- Working tree was clean at inspection.
- Specification: `implementation-plan.md`
- Build instructions: `Documentation/RuntimeBuild.md`
- Prior chat: “Plan standalone MAMP Pro clone”. Its last recorded turn ended at a usage limit; the repository and artifacts contain later progress, so use this filesystem checkpoint when resuming.
- Preserve the established practice of committing each completed step separately.

## Agreed product scope

DevStack is an MIT-licensed native SwiftUI application, bundle ID `app.devstack.desktop`, for Apple Silicon macOS 27+. A fresh offline installation must work without Homebrew, MacPorts, Rosetta, or first-run downloads.

PHP 8.5.11 and MySQL 8.4.11 are the defaults. PHP 7.4.33 and MySQL 5.7.44 are legacy options requiring successful native feasibility gates. The selected scope uses custom hostnames and ports 80/443 through a privileged helper. Mailpit, phpMyAdmin, Composer, SSL, diagnostics, and signed offline runtime imports are included. MariaDB and MailHog are outside the agreed scope.

## Implemented in source

- Swift package and Xcode workspace with app, core library, privileged helper, runtime packager, and `DevStackCoreChecks` products.
- SwiftUI Dashboard, Sites, PHP, Database, Mailpit, Logs, Doctor, and Settings screens; menu-bar controls, login-item registration, and quit/service-stop confirmation.
- Persistent configuration, hostname validation, Apache/PHP-FPM/MySQL configuration generation, subprocess supervision, readiness checks, and captured logs.
- Typed XPC helper operations for managed hosts, loopback port forwarding, CA trust, and cleanup, with client authentication and constrained inputs.
- Local CA/leaf certificate generation and renewal, separate MySQL data directories, initialization, development credentials, and SQL backup/import/export/reset workflows.
- Runtime provenance/EOL UI, extension controls, managed shell/environment actions, Composer self-update protection, and Mailpit controls.
- Signed runtime-pack creation/import verification, checksum and Mach-O inspection, Doctor diagnostics, and redacted support export.
- Locked source/dependency/build-tool manifests; fetch, build, relocation, audit, license, SBOM, legacy-gate, signing, and DMG scripts.

These are implemented code paths. End-to-end behavior with the packaged stack remains to be verified.

## Runtime and artifact state

| Component | Staged payload | Included in current preview |
| --- | --- | --- |
| Apache 2.4.68 | Version command passed | Yes |
| PHP 8.5.11 CLI/FPM | CLI version command passed | Yes |
| MySQL 8.4.11 | `mysqld --version` passed, native arm64 | Yes |
| OpenSSL 3.5.8 | Version command passed | Yes |
| Mailpit 1.31.1 | Binary present and executable | Yes |
| phpMyAdmin 5.2.3 | Files present | Yes |
| Composer 2.10.3 | Files present | Yes |
| ImageMagick 7.1.2-32 | Files present | Yes |
| PHP 7.4.33 | CLI version command passed; gate not established | No |
| MySQL 5.7.44 | No staged runtime | No |
| Xdebug, Redis, Imagick PHP modules | Missing from both staged PHP runtimes | No |

The runtime table distinguishes executable smoke checks from full integration or regression tests.

Artifacts:

- `.build/release/DevStack.app`
- `.build/release/DevStack-0.1.0-arm64.dmg` — 861,744,729 bytes, approximately 822 MiB; modified at 22:52 Istanbul time on 29 September.
- Staged runtimes: `.build/Runtimes/`
- Isolated dependencies: `.build/runtime-dependencies/`
- Source/build trees: `.build/runtime-work/`
- Cached sources: `.build/runtime-cache/`
- Build logs: `.build/logs/`
- Generated notices/SBOM: `ThirdPartyNotices/` and `SBOM/`

The app and DMG have ad-hoc signatures and no TeamIdentifier. Deep/strict app signature verification passed, which confirms local signature integrity, not Developer ID distribution readiness. Offline Gatekeeper acceptance has not been established.

No runtime build processes were active during inspection. The development app was running; backend services were not observed in the process check.

Build outputs, caches, notices, and SBOM directories are ignored by Git. A repository clone will need to rebuild these artifacts or receive them separately.

## Verification and unresolved build failures

- Re-ran `.build/out/Products/Release/DevStackCoreChecks`: **all checks passed**.
- Re-ran version commands successfully for staged Apache, PHP 8.5, PHP 7.4, MySQL 8.4, and OpenSSL.
- `.build/logs/build-runtimes-final.log` ends with a successful relocation/runtime audit. That audit predates the latest PHP 7.4 payload; it does not verify all current staged files.
- `.build/logs/build-runtimes-php74.log` ends with a build-time loader failure for bare `libicuio.78.dylib`, followed by `ext/phar/phar.php` Error 134. An installed PHP 7.4 CLI now runs, but the log is not evidence of a completed build or passing gate.
- `.build/logs/package-release.log` ends with an app-signing “No such file or directory” failure. The later app/DMG artifacts exist and the current app signature verifies; that older log does not document their successful packaging.
- Full applicable upstream suites, legacy gates, helper installation, site serving, database switching, mail delivery, and clean-machine offline acceptance are not established by these checks.
- The selected developer directory is `/Library/Developer/CommandLineTools`; full Xcode is not selected.

## Remaining implementation work found during inspection

1. **Imported runtime selection:** packs install into Application Support and their manifests enter the catalog, but configuration generation, required-runtime checks, and service launch still resolve through `paths.builtInRuntimes`, with hard-coded PHP 7.4/8.5 IDs. Connect imported runtime paths and manifest-driven versions to actual execution.
2. **Crash recovery:** `ServiceSupervisor` tracks current `Process` objects in memory. Its reconciliation handles exits within the current session; cross-launch PID/executable/UID identity reconciliation remains to be implemented.
3. **Site updates and rollback:** `saveSite` restores stored/generated configuration on error but does not restore previously applied privileged host mappings. `deleteSite` currently saves and regenerates configuration without applying host changes or reloading live Apache. Complete and test the running-site update transaction.

## Next steps

1. Resolve the PHP 7.4 build-time ICU loader issue, complete its build, and audit the current staged payload. Build ABI-specific Xdebug, Redis, and Imagick modules for both PHP versions.
2. Build native MySQL 5.7 and run its initialization/transaction/restart-integrity gate. Run the PHP 7.4/OpenSSL regression and extension gate before including legacy runtimes.
3. Complete the application gaps above and test the modern stack end to end, then both PHP versions and both database engines, including phpMyAdmin, HTTPS, and PHP mail capture.
4. Run all required upstream suites and review recorded dependency-suite failures. Preview suite deferral is not release validation.
5. Repackage with a Developer ID Application identity and notarization profile; verify signatures, stapling, and Gatekeeper behavior.
6. Perform the full acceptance run on a fresh macOS 27 Apple Silicon installation with networking disabled.

Packaging currently removes a staged legacy runtime when its feasibility gate fails. Preserve a needed staging copy before invoking `scripts/package-release.sh` during troubleshooting.

## Resume commands

```sh
cd /Users/serkan/Desktop/localhost
export PATH="$PWD/.build/build-tools/bin:$PATH"
git status --short --branch
scripts/build-status.sh
swift build --build-system native --jobs 4
swift run --build-system native DevStackCoreChecks
```

Use targeted runtime builds while resolving failures; `scripts/build-runtimes.sh all` recreates component build trees. See `Documentation/RuntimeBuild.md` for the full pipeline. Do not delete user data under `~/Library/Application Support/DevStack` or logs under `~/Library/Logs/DevStack` as part of a build cleanup.
