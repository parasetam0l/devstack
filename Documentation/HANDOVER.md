# DevStack handover

Verified 30 September 2026 on Apple Silicon macOS 27.0.1 (Europe/Istanbul).

## Usable build

The installed application is `/Applications/DevStack.app`. The final app is `.build/release/DevStack.app`; its approximately 451 MiB disk image is `.build/release/DevStack-0.1.0-arm64.dmg`. This is an ad-hoc development build, not a Developer ID/notarized distribution.

The modern stack works on this computer using loopback HTTP 8080 and HTTPS 8443. Apache is selected by default; Nginx is bundled and remains disabled until selected. PHP 8.5 is the default for new sites and Terminal. Existing sites keep their own PHP version.

## Included runtimes

| Component | Version | Verified behavior |
| --- | --- | --- |
| Apache | 2.4.68 | Site routing, both PHP versions, HTTPS, management tools |
| Nginx | 1.30.5 | Same ports, live switching, HTTPS, FastCGI, management tools |
| PHP | 8.5.11 and 8.4.26 | Independent FPM pools, per-site selection, CLI |
| MySQL | 8.4.11 | First-run initialization, authenticated connections, SQL export/import |
| PostgreSQL | 18.6 | Private cluster, SCRAM authentication, verified TLS, SQL export/import, independent controls |
| Mailpit | 1.31.1 | SMTP capture from PHP mail(), inbox API |
| phpMyAdmin | 5.2.3 | Login page served through both web servers |
| Adminer | 6.1.1, full English build | MySQL and PostgreSQL drivers; login page served through both web servers |
| OpenSSL | 3.5.8 | CA and leaf generation, certificate verification |
| Composer | 2.10.3 | Managed wrapper, selected PHP and immutable bundled PHAR |
| Xdebug / Redis / Imagick | 3.5.3 / 6.3.0 / 3.8.1 | ABI-specific modules for both PHP versions; Xdebug loads, Redis class and PNG operations work |
| ImageMagick | 7.1.2-32 | PNG/JPEG delegates and explicit installed configuration paths |

PHP 7.4 and MySQL 5.7 are not shipped. Their native feasibility gates did not pass. The PHP Redis extension is included; a Redis server is not bundled.

## Implemented behavior

- Compact native Liquid Glass panels, controls, sidebar and desktop backdrop with neutral colors. Default window is 920 × 620 points; minimum 820 × 540; maximum width 1100. Oversized restored frames are reduced on launch. Simple solid app icon is preserved; the menu-bar template now has separate open layers and a terminal mark.
- One Apache/Nginx selector and one PHP selector, with separate Start/Stop/Restart/Logs actions for each service. MySQL and PostgreSQL have separate version selectors, including No MySQL / No PostgreSQL; Start Stack includes only selected databases. Disabling either preserves its data.
- Site creation, live apply, deletion without deleting project files, dedicated PHP pools, HTTPS certificates and request limits.
- Durable process identity journal with PID/executable/user/start-time validation; owned-process recovery across app launches; independent service controls and startup rollback.
- MySQL backups, streamed SQL import/export, separate data directories, and interrupted first-run credential recovery. PostgreSQL uses an atomic private initialization, loopback-only configuration, SCRAM and a managed TLS certificate. PostgreSQL imports create a backup first and preserve the managed login role.
- SSL tab: compact certificate list, issue/renew, metadata and fingerprints, CA trust/export, certificate export/reveal, and deletion restricted to unused certificates. Renew reloads running web services and PostgreSQL configuration.
- Both PHP versions include ABI-specific pgsql and pdo_pgsql extensions and bundled libpq. Adminer supports both database engines; phpMyAdmin remains MySQL-specific.
- Extension controls, managed Terminal environment, Composer and MySQL/PostgreSQL wrappers, diagnostics and support export.
- Imported runtime directory resolution, signed runtime-pack verification, typed privileged helper operations.

## Verification evidence

`DevStackCoreChecks` passes, including schema-1 migration to the additive PostgreSQL configuration, all four database-selection combinations, No MySQL guards, and a bounded command timeout. The exact installed PostgreSQL payload passed `DevStackRuntimeChecks` (evidence `/tmp/dvs-check-2F969894`): isolated MySQL and PostgreSQL initialization/authentication/export/import; PostgreSQL verify-full TLS; SSL metadata/forced renewal/unused certificate deletion; both PHP PostgreSQL APIs and PDO drivers through Apache and Nginx; HTTPS, Imagick PNG, Redis, Xdebug loading, phpMyAdmin/full Adminer rendering, Mailpit delivery, and three PostgreSQL restart cycles with independent database stop.

Native UI checks verified neither/MySQL-only/PostgreSQL-only/both selections (3/4/4/5 running services), independent MySQL and PostgreSQL stop, and certificate renewal while both databases stayed running. The retained `site-1.localhost` project served PHP 8.5 through CA-verified HTTPS after renewal. Project files and both database directories are preserved. Defaults remain Apache and PHP 8.5; Nginx remains stopped. No Desktop permission prompt appeared.

The compact UI was inspected through native accessibility and screenshots on every page, including the site editor and advanced settings, six certificate rows, database connection tools, light/system appearance and a single matching sidebar toggle. Services, sites, extensions, certificates and diagnostics use dense rows; certificate metadata is opened in a sheet. Settings is one compact panel. Buttons use the same native interactive glass style without a colored fill or oversized toolbar background.

Repeated shutdown exposed a Foundation `Process.waitUntilExit` hang in a cooperative executor after the process had already exited. Service shutdown now polls verified process ownership with bounded deadlines; PostgreSQL receives fast-shutdown SIGINT. The generic command runner also has bounded exit cleanup. Installed UI Stop Stack and repeated runtime restart checks passed after this fix.

The Desktop-access defects were real compiled-path lookups: SwiftPM resources, OpenSSL configuration/certificates, ImageMagick configuration, and MySQL defaults/character sets/client plug-ins. Packaged resource lookup, explicit environment/pool configuration, the ImageMagick patch, and MySQL arguments/wrappers now resolve installed paths.

Targeted PHP upstream tests passed with zero failures: 1,369 passed/855 skipped for PHP 8.4 and 1,395 passed/895 skipped for PHP 8.5. These covered OpenSSL, curl, hash, PHAR, mysqli, PDO MySQL, GD and ZIP. Database-dependent cases skipped in that upstream run were covered separately by runtime integration.

The broad overnight suites did **not** pass. PHP 8.5 reported 92 failures out of 22,124 cases; PHP 8.4 did not finish its summary. Failures included JIT memory protection, platform iconv behavior and conflicting test ports. PHP debugger watchpoint children remained alive and the computer experienced severe memory pressure and a freeze. A restart cleared them. Broad suites were stopped; automated recipes now exclude phpdbg watchpoint tests, run serially, and use `scripts/run-bounded-check.py` for time, CPU, RSS, wired-memory limits and process-group cleanup. Timeout and orphan-child cleanup behavior were verified. Generated PHP configuration explicitly disables JIT.

Logs are under `.build/logs/`: `core-checks.log`, `runtime-integration.log`, `runtime-integration-final.log`, `php84-regression.log`, `php85-regression.log`, `php85-full-suite.log`, `php84-full-suite.log`, `package-release-final.log`, `postgresql-installed-integration.log`, `postgresql-core-checks.log`, `dense-ui-build.log`, `dense-ui-core-checks.log`, `dense-ui-release.log`. Build products and logs are ignored by Git.

## Concrete limitations

1. No Developer ID identity or notarization credentials are installed. Production helper authentication remains fail-closed. This build cannot enable privileged custom-host mappings or ports 80/443. `.localhost` and ports 8080/8443 work without the helper.
2. The CA is generated but has not been authorized in macOS trust settings. Browser-trusted HTTPS requires the user to use SSL → Trust CA and complete the native macOS authorization. Certificate verification itself passed using the generated CA.
3. Broad upstream regression acceptance, complete extension upstream suites, offline Gatekeeper acceptance and a fresh-machine offline run remain unverified. JIT and legacy runtimes are not supported by this build.
4. Only MySQL 8.4 and PostgreSQL 18 are shipped. Legacy MySQL and other PostgreSQL versions are not verified. PostgreSQL SQL imports can require matching extensions and inactive external connections; imports from other database dialects are not supported.

Do not label this a production-complete MAMP Pro replacement. The requested modern local stack is functional, with distribution and acceptance work still outstanding.

## Resume safely

Keep one bounded check running at a time. Do not repeat broad PHP/phpdbg suites on this host. Do not grant Desktop access to work around compiled-path bugs. Do not weaken helper signature requirements for an ad-hoc app. Do not delete user data under Application Support or Logs during cleanup.

```sh
cd /Users/serkan/Desktop/localhost
swift build --jobs 2
/usr/bin/python3 scripts/run-bounded-check.py --seconds 30 -- "$(swift build --show-bin-path)/DevStackCoreChecks"
# Stop the app stack before this integration check; it uses loopback ports 3306, 5432, 8080, 8443 and 8025.
/usr/bin/python3 scripts/run-bounded-check.py --seconds 300 -- "$(swift build --show-bin-path)/DevStackRuntimeChecks" .build/Runtimes
```
