# DevStack — Offline macOS Development Stack

## Summary

Build an MIT-licensed, Apple Silicon–only SwiftUI app for macOS 27+ under bundle ID `app.devstack.desktop`. DevStack will require no Homebrew, Rosetta, internet connection, or first-run downloads.

Bundle:

- Apache 2.4.68
- PHP 7.4.33 and PHP 8.5.11
- MySQL 5.7.44 and MySQL 8.4.11 LTS
- phpMyAdmin 5.2.3
- Mailpit 1.31.1
- Composer 2.10.3
- Version-compatible Xdebug, Redis, and Imagick extensions

PHP 8.5 and MySQL 8.4 are the defaults. PHP 7.4 and MySQL 5.7 are explicitly labeled legacy/EOL and are activated only when selected.

PHP 7.4 support is conditional on producing a stable native ARM64 build using OpenSSL 3.5.8 LTS. PHP 7.4 officially lacks OpenSSL 3 compatibility, so a backport patch and full regression test are required; DevStack will not bundle unsupported OpenSSL 1.1.1 as a workaround. [PHP/OpenSSL compatibility](https://github.com/php/php-src/issues/9503) [OpenSSL support policy](https://openssl-library.org/policies/releasestrat.html)

## Key Implementation Changes

### Runtime build and packaging

- Create an Xcode workspace containing the SwiftUI app, `DevStackCore` package, privileged `app.devstack.desktop.helper`, and unit/integration test targets.
- Maintain a lockfile containing every source URL, version, SHA-256, license, patch, build flag, architecture, and runtime dependency.
- Use independent dependency trees for each runtime to prevent incompatible libraries from leaking between PHP, Apache, and MySQL.
- First complete two feasibility gates:
  1. Native MySQL 5.7.44 ARM64 initialization, CRUD, transactions, shutdown, restart, and data-integrity testing.
  2. Native PHP 7.4.33 NTS CLI/FPM build against OpenSSL 3.5.8, including the full applicable PHP and OpenSSL extension test suites.
- If PHP 7.4 requires an unsupported SSL library or fails its regression gate, omit it rather than shipping an insecure runtime; PHP 8.5 remains functional.
- Build all PHP extensions separately for each PHP ABI. Use Xdebug 3.1.6 for PHP 7.4 and Xdebug 3.5.3 for PHP 8.5.
- Rewrite Mach-O install names/RPATHs and reject artifacts referring to Homebrew, MacPorts, or build-machine paths.
- Store immutable built-in runtimes inside the application bundle. Store imported runtime packs, generated configuration, databases, certificates, and logs in Application Support.
- Sign all nested binaries, dylibs, PHP extensions, runtime packs, and helpers before signing, notarizing, and stapling the final DMG.

### Runtime packs

- Define a signed `.devstack-runtime` archive format containing a manifest, payload, checksums, licenses, SBOM fragment, and supported macOS/architecture declarations.
- Verify the archive signature, manifest schema, hashes, code signatures, architecture, and dependency paths before import.
- Install imported packs under `~/Library/Application Support/DevStack/Runtimes`; never modify the signed application bundle.
- Include PHP 7.4 and 8.5 inside the full initial DMG, while allowing later PHP versions and extensions to be imported offline from local files or USB media.
- Never download runtime packs from within DevStack v1.

### Application and service management

- Provide Dashboard, Sites, PHP, Database, Mailpit, Logs, Doctor, and Settings screens plus a menu-bar controller.
- Represent each service as `stopped`, `starting`, `running`, `stopping`, or `failed`, with readiness probes, timeouts, captured logs, and recovery actions.
- Run Apache, PHP-FPM, MySQL, and Mailpit as the logged-in user:
  - Apache internal listeners: `8080` and `8443`
  - MySQL: `127.0.0.1:3306`
  - Mailpit SMTP/UI: `127.0.0.1:1025` and `127.0.0.1:8025`
  - Xdebug: `127.0.0.1:9003`
- Require Pro mode with custom hostnames and ports 80/443; no high-port or `.localhost` fallback is included.
- Install a narrowly scoped helper through `SMAppService` that only maintains DevStack’s marked `/etc/hosts` section, forwards loopback 80→8080 and 443→8443, manages CA trust, and removes privileged state.
- Authenticate helper calls with the app’s code signature. Reject arbitrary commands, executable paths, file writes, and shell text.
- Closing the window leaves the menu-bar controller active. Quitting offers to stop all services. Optional start-at-login uses the native login-item API.

### Sites, PHP, and SSL

- Support multiple sites with hostname, document root, SSL, PHP version, PHP limits, extension profile, and per-site logs.
- Accept valid ASCII hostnames; reject duplicates, IP literals, wildcards, malformed labels, and configuration metacharacters.
- Permit arbitrary valid hostnames but warn that `/etc/hosts` can shadow a real domain.
- Generate Apache and PHP-FPM configurations atomically, run syntax checks, and roll back configuration and host mappings if reload fails.
- Run separate PHP-FPM masters for PHP 7.4 and 8.5, with per-site pools and Unix sockets. Both versions may serve different sites simultaneously.
- Default new sites to PHP 8.5. Selecting PHP 7.4 requires acknowledging an EOL warning.
- Bundle common extensions for both runtimes where compatible: bcmath, bz2, calendar, curl, DOM/XML/XSL, exif, fileinfo, FTP, GD, gettext, GMP, intl, mbstring, mysqli/mysqlnd, OPcache, pcntl, PDO MySQL/SQLite, SOAP, sockets, sodium, SQLite3, tidy, and zip.
- Provide per-runtime toggles for Xdebug, Redis, and Imagick. Xdebug is disabled by default.
- Generate a local CA and per-site certificates with OpenSSL 3.5.8. Store private keys with mode `0600`, trust only the public CA, renew leaf certificates automatically, and reload Apache after validation.
- Run phpMyAdmin through a dedicated PHP 8.5 management pool at `https://phpmyadmin.devstack.test`, independent of each site’s selected PHP version.

### Database behavior

- Keep MySQL 5.7 and 8.4 in separate data directories; only one engine can own port 3306.
- Default to MySQL 8.4 LTS. MySQL 5.7 is disabled until explicitly selected and always shows an EOL warning.
- Initialize each engine independently, bind it to loopback, and use `root` / `root` with a local-development-only warning.
- Switching engines gracefully stops the current version and starts the selected version. Never share or automatically upgrade data files.
- Provide explicit SQL export/import using the matching bundled `mysqldump` and `mysql` clients.
- Create a timestamped SQL backup before destructive reset or assisted cross-version import.
- Test PHP 7.4’s mysqlnd authentication against MySQL 8.4’s default authentication before allowing that combination in the UI.
- MySQL 8.4 replaces 8.0 because 8.0 entered sustaining support in April 2026, while 8.4 is the supported LTS line. [MySQL lifecycle](https://www.mysql.com/support/eol-notice.html)

### Mailpit and Composer

- Bundle Mailpit 1.31.1 as a standalone ARM64 binary with persistent SQLite storage.
- Expose it through Apache at `https://mailpit.devstack.test`.
- Configure both PHP versions with:

  `sendmail_path = "/Applications/DevStack.app/.../mailpit sendmail -S 127.0.0.1:1025"`

- Configure allowed hosts, disable external SMTP relay/release, and provide UI actions to open or clear captured mail.
- Bundle Composer 2.10.3 and run it using the PHP version selected for the managed shell or site.
- Disable replacement of the bundled Composer binary through `self-update`; package installation remains available when the machine has network access or a populated Composer cache.
- Provide “Open Managed Shell” and a copyable environment command without modifying shell startup files.

### Diagnostics and supply-chain visibility

- Add DevStack Doctor checks for port ownership, helper authorization, `/etc/hosts`, CA trust, certificate expiry, folder access, configuration syntax, service readiness, signatures, architecture, RPATHs, database state, and available disk space.
- Generate an optionally exportable redacted support archive containing diagnostics, manifests, generated configs, and recent logs but excluding database contents, private keys, and credentials.
- Generate a CycloneDX or SPDX SBOM for each release and runtime pack.
- Show runtime support state and build provenance in the UI, including permanent EOL badges for PHP 7.4 and MySQL 5.7.

## Public Interfaces and Types

- `RuntimeManifest`: ID, kind, version, ABI, architecture, entry points, extensions, hashes, license, source provenance, support state, and dependency paths.
- `RuntimePackManifest`: schema version, payload inventory, compatibility requirements, signing identity, SBOM location, and checksums.
- `SiteDefinition`: UUID, hostname, document root, TLS state, PHP runtime ID, PHP overrides, extension profile, and log locations.
- `AppConfiguration`: schema version, sites, selected MySQL engine, extension toggles, login-start preference, and imported runtime inventory.
- `ServiceState` and `ServiceFailure`: lifecycle state, exit code, failed readiness probe, log excerpt, and recovery action.
- `DiagnosticReport`: structured check results with severity, evidence, remediation, and redaction state.
- `PrivilegedHelperProtocol`: typed `applyHostMappings`, `setPortForwarding`, `trustLocalCA`, `removeManagedState`, and `status` operations only.

## Test and Acceptance Plan

- Unit-test hostname validation, escaping, atomic rollback, config generation, manifest verification, runtime-pack rejection, schema migration, lifecycle transitions, and helper validation.
- Audit all packaged code for ARM64, signatures, permitted RPATHs, and absence of package-manager paths.
- Run applicable PHP test suites for both versions, extension tests, TLS tests, and representative legacy PHP 7.4 and modern PHP 8.5 applications.
- Verify simultaneous PHP 7.4 and 8.5 sites, version switching, extension isolation, CLI/FPM parity, Xdebug, Composer, and PHP mail delivery.
- Test MySQL isolation, repeated switching, backup/export/import, phpMyAdmin, and every supported PHP/MySQL pairing.
- Test Mailpit persistence, attachments, HTML rendering, search/deletion, API access, and restart recovery.
- Test custom hostnames, HTTPS trust, certificate renewal, helper install/removal, port conflicts, crash recovery, login launch, and complete cleanup.
- Validate DevStack Doctor on healthy and intentionally broken installations and verify support-bundle redaction.
- Final acceptance runs on a clean macOS 27 Apple Silicon installation with networking disabled.
- The release is complete only when the signed and stapled DMG passes Gatekeeper offline and every bundled feature works without Homebrew, Rosetta, or downloads.

## Assumptions and Defaults

- Target is ARM64 macOS 27.0+ only.
- Custom hostnames and privileged ports 80/443 are mandatory.
- PHP 8.5 and MySQL 8.4 are defaults; PHP 7.4 and MySQL 5.7 are legacy compatibility options.
- The build/notarization machine may access the internet; the installed app performs no required downloads.
- Final distribution requires Apple Developer Program enrollment.
- DevStack uses MIT and ships third-party notices, corresponding GPL sources, patches, and SBOMs.
- App Sandbox is disabled for user-selected document roots; hardened runtime remains enabled.
- No MailHog, MariaDB, Redis server, PostgreSQL, automatic updater, or live extension compilation is included in v1.
