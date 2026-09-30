# DevStack morning handover

Verified 30 September 2026 on Apple Silicon macOS 27.0.1 (Europe/Istanbul).

## Usable build

The installed application is `/Applications/DevStack.app`. The final app is `.build/release/DevStack.app`; its 387 MiB disk image is `.build/release/DevStack-0.1.0-arm64.dmg`. This is an ad-hoc development build, not a Developer ID/notarized distribution.

The modern stack works on this computer using loopback HTTP 8080 and HTTPS 8443. Apache is selected by default; Nginx is bundled and remains disabled until selected. PHP 8.5 is the default for new sites and Terminal. Existing sites keep their own PHP version.

## Included runtimes

| Component | Version | Verified behavior |
| --- | --- | --- |
| Apache | 2.4.68 | Site routing, both PHP versions, HTTPS, management tools |
| Nginx | 1.30.5 | Same ports, live switching, HTTPS, FastCGI, management tools |
| PHP | 8.5.11 and 8.4.26 | Independent FPM pools, per-site selection, CLI |
| MySQL | 8.4.11 | First-run initialization, authenticated connections, SQL export/import |
| Mailpit | 1.31.1 | SMTP capture from PHP mail(), inbox API |
| phpMyAdmin | 5.2.3 | Login page served through both web servers |
| Adminer | 6.1.1 | Login page served through both web servers |
| OpenSSL | 3.5.8 | CA and leaf generation, certificate verification |
| Composer | 2.10.3 | Managed wrapper, selected PHP and immutable bundled PHAR |
| Xdebug / Redis / Imagick | 3.5.3 / 6.3.0 / 3.8.1 | ABI-specific modules for both PHP versions; Xdebug loads, Redis class and PNG operations work |
| ImageMagick | 7.1.2-32 | PNG/JPEG delegates and explicit installed configuration paths |

PHP 7.4 and MySQL 5.7 are not shipped. Their native feasibility gates did not pass. The PHP Redis extension is included; a Redis server is not bundled.

## Implemented behavior

- Native Liquid Glass panels, controls, sidebar, and desktop backdrop; teal accent; simple solid icon and matching menu-bar symbol; window width capped at 1400 points.
- One Apache/Nginx selector and one PHP selector, with separate Start/Stop/Restart/Logs actions for each service.
- Site creation, live apply, deletion without deleting project files, dedicated PHP pools, HTTPS certificates and request limits.
- Durable process identity journal with PID/executable/user/start-time validation; owned-process recovery across app launches; independent service controls and startup rollback.
- MySQL backups, streamed SQL import/export, separate data directories, and interrupted first-run credential recovery.
- Extension controls, managed Terminal environment, Composer and MySQL wrappers, diagnostics and support export.
- Imported runtime directory resolution, signed runtime-pack verification, typed privileged helper operations.

## Verification evidence

`DevStackCoreChecks` passes. `DevStackRuntimeChecks` passes against the exact final packaged payload (evidence `/tmp/dvs-check-2966263D`): isolated MySQL initialization/authentication/export/import, Apache and Nginx HTTPS, PHP 8.4/8.5, Imagick PNG, Redis, Xdebug loading, phpMyAdmin/Adminer rendering, Mailpit delivery, and independent service stop after ownership recovery.

The installed app was also tested through native UI: Start Stack completed within a few seconds; Apache→Nginx→Apache preserved other services; Mailpit and PHP could start/stop independently; a PHP 8.4 `verification.localhost` site was created live, returned its version through certificate-verified HTTPS, and was removed while keeping its files. Defaults were restored to Apache/PHP 8.5. No Desktop permission prompt appeared during the successful installed-app run.

The Desktop-access defects were real compiled-path lookups: SwiftPM resources, OpenSSL configuration/certificates, ImageMagick configuration, and MySQL defaults/character sets/client plug-ins. Packaged resource lookup, explicit environment/pool configuration, the ImageMagick patch, and MySQL arguments/wrappers now resolve installed paths.

Targeted PHP upstream tests passed with zero failures: 1,369 passed/855 skipped for PHP 8.4 and 1,395 passed/895 skipped for PHP 8.5. These covered OpenSSL, curl, hash, PHAR, mysqli, PDO MySQL, GD and ZIP. Database-dependent cases skipped in that upstream run were covered separately by runtime integration.

The broad overnight suites did **not** pass. PHP 8.5 reported 92 failures out of 22,124 cases; PHP 8.4 did not finish its summary. Failures included JIT memory protection, platform iconv behavior and conflicting test ports. PHP debugger watchpoint children remained alive and the computer experienced severe memory pressure and a freeze. A restart cleared them. Broad suites were stopped; automated recipes now exclude phpdbg watchpoint tests, run serially, and use `scripts/run-bounded-check.py` for time, CPU, RSS, wired-memory limits and process-group cleanup. Timeout and orphan-child cleanup behavior were verified. Generated PHP configuration explicitly disables JIT.

Logs are under `.build/logs/`: `core-checks.log`, `runtime-integration.log`, `runtime-integration-final.log`, `php84-regression.log`, `php85-regression.log`, `php85-full-suite.log`, `php84-full-suite.log`, `package-release-final.log`. Build products and logs are ignored by Git.

## Concrete limitations

1. No Developer ID identity or notarization credentials are installed. Production helper authentication remains fail-closed. This build cannot enable privileged custom-host mappings or ports 80/443. `.localhost` and ports 8080/8443 work without the helper.
2. The CA is generated but has not been authorized in macOS trust settings. Browser-trusted HTTPS requires the user to use Settings → Trust DevStack CA and complete the native macOS authorization. Certificate verification itself passed using the generated CA.
3. Broad upstream regression acceptance, complete extension upstream suites, offline Gatekeeper acceptance and a fresh-machine offline run remain unverified. JIT and legacy runtimes are not supported by this build.
4. Only MySQL 8.4 is shipped. There is no tested MySQL 5.7 switching path in the delivered payload.

Do not label this a production-complete MAMP Pro replacement. The requested modern local stack is functional, with distribution and acceptance work still outstanding.

## Resume safely

Keep one bounded check running at a time. Do not repeat broad PHP/phpdbg suites on this host. Do not grant Desktop access to work around compiled-path bugs. Do not weaken helper signature requirements for an ad-hoc app. Do not delete user data under Application Support or Logs during cleanup.

```sh
cd /Users/serkan/Desktop/localhost
swift build --build-system native --jobs 2
/usr/bin/python3 scripts/run-bounded-check.py --seconds 30 -- .build/arm64-apple-macosx/debug/DevStackCoreChecks
# Stop the app stack before this integration check; it uses loopback ports 3306, 8080, 8443 and 8025.
/usr/bin/python3 scripts/run-bounded-check.py --seconds 120 -- .build/arm64-apple-macosx/debug/DevStackRuntimeChecks .build/Runtimes
```
