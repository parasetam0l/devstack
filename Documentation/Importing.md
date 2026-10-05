# Importing from other apps

**Import from Another App…** brings the projects and databases of another
local stack into DevStack. You open it from the File menu, the Sites toolbar,
or the last step of the setup wizard. The list shows only the apps that are
installed and that DevStack can import from; XAMPP is the first, and MAMP,
MAMP PRO, Laravel Herd, Laravel Valet and Local appear once they are
supported.

The other app is only ever read. Projects are copied (cloned on APFS, so a
copy from /Applications to the home folder takes no extra space), and
databases are read from a copy of the data folder.

## XAMPP

| Step | What happens |
|---|---|
| Find | Every `/Applications/*/xamppfiles` with a `properties.ini`. The version gives the PHP version: XAMPP 8.2.4 ships PHP 8.2. |
| Check | Projects in `htdocs` and the virtual hosts (when `httpd.conf` includes `httpd-vhosts.conf`), the database folders, the MariaDB binary's architecture (Rosetta), running XAMPP servers, runtimes to install, disk space. |
| Choose | Each folder answers at `https://localhost/<folder>` as it did in XAMPP, or at a host of its own (the default for a `public/` web root or a virtual host). A project with its own host shows its document root: `~/DevStack/<name>` plus its web root. The web root is picked from the project's folders; **Choose…** puts the project elsewhere, into an empty folder or a new folder inside a non-empty one. Database name clashes are renamed (`name_xampp`), replaced after a backup, or skipped. |
| Copy | Folders go to `~/DevStack/<name>`, or into the localhost site's folder for `localhost/…` addresses. Each copy goes through a hidden staging folder and is renamed at the end, so a cancelled copy leaves nothing. |
| Databases | XAMPP's data folder is copied (with an administrator prompt, since it belongs to `_mysql`). XAMPP's own MariaDB then starts on the copy with no network port and no grant tables. If XAMPP was updated without `mysql_upgrade`, its system tables are older than the server (say, MariaDB 10.1 data under 10.4). Routines and events then can't be read, so XAMPP's `mysql_upgrade --upgrade-system-tables` runs on the copy first. The server is restarted with grant tables when root has no password, because MariaDB hides events without them. Each database is counted (rows per table, views, routines, triggers, events), exported with XAMPP's mysqldump into `Backups/XAMPP import <date>/`, converted by `MariaDBDumpConverter`, imported and counted again. |
| Settings | Optionally: root signs in without a password, as in XAMPP; XAMPP's SQL mode; accounts other than root and pma are recreated with their password hash (MySQL 8.4 then loads `mysql_native_password`). In the copies only, `wp-config.php` and `.env` follow renamed databases, MySQL's port and the new address, and WordPress's stored addresses are replaced serialized-safe. Each changed file keeps a `.xampp-backup`. |
| After | The stack starts, each site is requested straight from the web server and its error log read; database differences are listed; `Report.md` sits beside the exports. |

### MariaDB to MySQL

`MariaDBDumpConverter` streams the export line by line and changes only
definitions, never row data. Newer exports put each row on its own line, so
everything up to the `;` that ends an `INSERT` passes through untouched.

- Aria becomes InnoDB, and Aria's table options are dropped.
- `uuid`/`inet` become text columns.
- `PERSISTENT` becomes `STORED`.
- Literal and computed defaults become expressions (8.4) or are dropped (5.7).
- Generated columns get `DEFAULT` in rows.
- `nopad` and `uca1400` collations are mapped.
- Per-table constraint names (`CONSTRAINT_1`, `1`) are dropped, because MySQL needs them unique per database.
- SQL modes MySQL lacks are filtered.
- Definers become `CURRENT_USER`.
- Six-digit version comments are neutralised.
- Sequences are left out and reported.

### Testing

`DevStackCoreChecks` covers detection, naming, the converter and the settings
updates. A file still being written must have its size read with
`FileSize.of`: a `URL`'s resource values are cached after the first read. The whole flow runs against a fake XAMPP whose `sbin/mysqld`,
`bin/mysql` and `bin/mysqldump` point at Homebrew's MariaDB:

```sh
.build/debug/DevStack --ui-review sites --migration-e2e /path/to/fake/Applications [--twice]
```

That imports into a throwaway DevStack: its own folders, high ports, the
installed runtimes, and no helper. It prints every step, result and note,
requests each site, and quits. Options:

- `--twice`: imports again into the same DevStack, to exercise name clashes.
- `--choose-folder`: puts the Laravel project in a chosen empty folder.
- `--cancel-after MS`: cancels the import after MS milliseconds.

To reproduce an XAMPP updated without `mysql_upgrade`, make the fixture's
data look like 10.1's: in `mysql.event` and `mysql.proc`, give `sql_mode`
the older SET without `EMPTY_STRING_IS_NULL`, `SIMULTANEOUS_ASSIGNMENT` and
`TIME_ROUND_FRACTIONAL`; drop `mysql.proc.aggregate`; and write
`10.1.8-MariaDB` into the upgrade info file. Screenshots of each wizard step:

```sh
.build/debug/DevStack --ui-review sites --pages sites --installed --migration source|check|choose|settings|importing|results --snapshot DIR
```

## Adding a source

Add the app to `MigrationSourceKind` and give it a finder and a scanner that
produce `MigrationProject`s and `MigrationDatabase`s, as `XAMPPInstallation`
and `XAMPPScanner` do. `TemporaryMariaDB`, `MariaDBDumpConverter`,
`DatabaseImporter`, `ProjectCopier` and `ProjectSettingsUpdater` work for any
MySQL-family source. MAMP's databases are MySQL, so they need no conversion.
