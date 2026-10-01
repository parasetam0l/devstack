import DevStackCore
import Foundation

struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct RuntimeChecks {
    static func main() async {
        if CommandLine.arguments.contains("--stop-owned-services") {
            let paths = DevStackPaths()
            let supervisor = ServiceSupervisor(recordsURL: paths.generated.appendingPathComponent("processes.json"))
            await supervisor.stopAll()
            let remaining = await supervisor.allStates().filter { $0.phase != .stopped }
            guard remaining.isEmpty else { fputs("Owned services still need attention\n", stderr); exit(1) }
            print("PASS: stopped verified DevStack-owned services")
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/Runtimes").standardizedFileURL
        let work = URL(fileURLWithPath: "/tmp/dvs-check-\(UUID().uuidString.prefix(8))")
        let paths = DevStackPaths(applicationSupport: work, logs: work.appendingPathComponent("Logs"), builtInRuntimes: root, defaultSiteRoot: work.appendingPathComponent("DevStack"))
        let supervisor = ServiceSupervisor(recordsURL: work.appendingPathComponent("processes.json"))
        do {
            try await run(root: root, paths: paths, supervisor: supervisor)
            await supervisor.stopAll()
            print("PASS: runtime integration checks. Evidence: \(work.path)")
        } catch {
            await supervisor.stopAll()
            fputs("FAIL: \(error.localizedDescription)\nEvidence: \(work.path)\n", stderr)
            exit(1)
        }
    }

    static func run(root: URL, paths: DevStackPaths, supervisor: ServiceSupervisor) async throws {
        let runner = ProcessRunner()
        let fm = FileManager.default
        try paths.createRequiredDirectories()
        let source = #"""
        <?php
        header('Content-Type: application/json');
        mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
        $db = new mysqli('127.0.0.1', 'root', 'root', 'devstack_smoke', 3306);
        $answer = $db->query('SELECT value FROM checks WHERE id=1')->fetch_assoc()['value'];
        $pg = new PDO('pgsql:host=127.0.0.1;port=5432;dbname=devstack_smoke', 'devstack', 'devstack');
        $pgAnswer = $pg->query('SELECT value FROM checks WHERE id=1')->fetchColumn();
        $pgNative = pg_connect('host=127.0.0.1 port=5432 dbname=devstack_smoke user=devstack password=devstack');
        $pgNativeAnswer = pg_fetch_result(pg_query($pgNative, 'SELECT value FROM checks WHERE id=1'), 0, 0);
        $image = new Imagick(); $image->newImage(2, 2, 'red'); $image->setImageFormat('png');
        $mail = mail('developer@example.test', 'DevStack smoke '.PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION, 'Captured by Mailpit');
        echo json_encode(['php'=>PHP_VERSION,'sql'=>$answer,'pgsql'=>$pgAnswer,'pgNative'=>$pgNativeAnswer,'mail'=>$mail,'png'=>strlen($image->getImageBlob())>0,'redis'=>class_exists('Redis'),'xdebug'=>extension_loaded('xdebug')]);
        """#
        var sites: [SiteDefinition] = []
        for id in ["php-8.5", "php-8.4"] {
            let project = paths.applicationSupport.appendingPathComponent("Project \(id)")
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try AtomicFileWriter.write(source, to: project.appendingPathComponent("index.php"), permissions: 0o644)
            let host = "\(id.replacingOccurrences(of: ".", with: "-")).localhost"
            sites.append(SiteDefinition(name: id, hostname: host, documentRoot: project.path, phpRuntimeID: id,
                logs: SiteLogPaths(access: paths.logs.appendingPathComponent("\(id)-access.log").path, error: paths.logs.appendingPathComponent("\(id)-error.log").path)))
        }
        let certificates = CertificateManager(paths: paths, openssl: root.appendingPathComponent("openssl-3.5/bin/openssl"))
        try certificates.ensureCertificates(for: sites.map(\.hostname) + ["phpmyadmin.localhost", "adminer.localhost", "mailpit.localhost", "postgresql.localhost"])
        try certificates.refreshTrustBundle()
        let renderer = ConfigurationRenderer(paths: paths, runtimeRoot: root)
        let apacheConfig = paths.generatedApache.appendingPathComponent("httpd.conf")
        let nginxConfig = paths.generatedNginx.appendingPathComponent("nginx.conf")
        try AtomicFileWriter.write(try renderer.apacheConfiguration(sites: sites), to: apacheConfig)
        try AtomicFileWriter.write(try renderer.nginxConfiguration(sites: sites), to: nginxConfig)
        try AtomicFileWriter.write(renderer.mysqlConfiguration(engine: .mysql84, baseDirectory: root.appendingPathComponent("mysql-8.4")), to: paths.generated.appendingPathComponent("mysql-8.4.cnf"))
        let database = DatabaseManager(paths: paths, runtimeRoot: root)
        _ = try database.initializeIfNeeded(.mysql84)
        try await supervisor.start(ServiceSpecification(kind: .mysql84, executable: root.appendingPathComponent("mysql-8.4/bin/mysqld"),
            arguments: ["--defaults-file=\(paths.generated.appendingPathComponent("mysql-8.4.cnf").path)"], logFile: paths.logs.appendingPathComponent("mysql.log"), readinessProbe: .tcpLoopback(port: 3306), readinessTimeout: 60))
        try database.configureDevelopmentRootPassword(.mysql84)
        guard database.ping(.mysql84) else { throw CheckFailure(message: "MySQL authentication failed") }
        guard !((try database.initializeIfNeeded(.mysql84))) else { throw CheckFailure(message: "Database initialization was repeated") }
        try database.configureDevelopmentRootPassword(.mysql84)
        let mysql = root.appendingPathComponent("mysql-8.4/bin/mysql")
        let sqlArgs = ["--no-defaults", "--character-sets-dir=\(root.appendingPathComponent("mysql-8.4/share/charsets").path)", "--socket=\(paths.sockets.appendingPathComponent("mysql.sock").path)", "--user=root"]
        _ = try runner.runChecked(executable: mysql, arguments: sqlArgs + ["-e", "CREATE DATABASE devstack_smoke; CREATE TABLE devstack_smoke.checks (id INT PRIMARY KEY, value VARCHAR(30)); INSERT INTO devstack_smoke.checks VALUES (1,'working');"], environment: ["MYSQL_PWD": "root"])
        let backup = try database.exportSQL(.mysql84, database: "devstack_smoke")
        _ = try runner.runChecked(executable: mysql, arguments: sqlArgs + ["-e", "TRUNCATE TABLE devstack_smoke.checks"], environment: ["MYSQL_PWD": "root"])
        try database.importSQL(.mysql84, source: backup, database: "devstack_smoke")
        print("PASS: MySQL initialization, authentication, export and import")
        let postgres = PostgreSQLManager(paths: paths, runtime: root.appendingPathComponent("postgresql-18"))
        try expectPostgres(try postgres.initializeIfNeeded(), "PostgreSQL was not initialized")
        try postgres.writeConfiguration()
        try await supervisor.start(postgres.specification)
        try expectPostgres(postgres.ping(), "PostgreSQL authentication failed")
        try expectPostgres(!(try postgres.initializeIfNeeded()), "PostgreSQL initialization was repeated")
        _ = try postgres.query("CREATE DATABASE devstack_smoke")
        _ = try postgres.query("CREATE TABLE checks (id integer PRIMARY KEY, value text); INSERT INTO checks VALUES (1,'working')", database: "devstack_smoke")
        let pgBackup = try postgres.exportSQL()
        _ = try postgres.query("UPDATE checks SET value='changed'", database: "devstack_smoke")
        try postgres.importSQL(source: pgBackup)
        try expectPostgres(try postgres.query("SELECT value FROM checks WHERE id=1", database: "devstack_smoke").trimmingCharacters(in: .whitespacesAndNewlines) == "working", "PostgreSQL backup did not restore its data")
        let verifiedConnection = "host=postgresql.localhost hostaddr=127.0.0.1 dbname=postgres sslmode=verify-full"
        try expectPostgres(try postgres.query("SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()", database: verifiedConnection).trimmingCharacters(in: .whitespacesAndNewlines) == "t", "PostgreSQL TLS verification failed")
        print("PASS: PostgreSQL initialization, SCRAM authentication, verified TLS, backup and restore alongside MySQL")
        let before = certificates.summary(of: paths.certificate(for: sites[0].hostname), hostname: sites[0].hostname)
        try certificates.ensureLeafCertificate(for: sites[0].hostname, force: true)
        let after = certificates.summary(of: paths.certificate(for: sites[0].hostname), hostname: sites[0].hostname)
        try expectPostgres(before.serial != after.serial && after.expiresAt != nil && !after.isExpired, "SSL renewal or metadata failed")
        try certificates.ensureLeafCertificate(for: "unused.localhost")
        try certificates.deleteLeafCertificate(for: "unused.localhost")
        try expectPostgres(!fm.fileExists(atPath: paths.certificate(for: "unused.localhost").path), "Unused certificate deletion failed")
        print("PASS: SSL certificate details, forced renewal and unused certificate deletion")

        try AtomicFileWriter.write(try renderer.phpMyAdminConfiguration(cookieSecret: "0123456789abcdefghijklmnopqrstuv"),
            to: paths.phpMyAdmin.appendingPathComponent("config.inc.php"), permissions: 0o600)
        try await supervisor.start(ServiceSpecification(kind: .mailpit, executable: root.appendingPathComponent("mailpit-1.31.1/mailpit"), arguments: renderer.mailpitArguments(), logFile: paths.logs.appendingPathComponent("mailpit.log"), readinessProbe: .tcpLoopback(port: 8025)))
        for site in sites {
            let id = site.phpRuntimeID
            let fpmConfig = paths.generatedPHP.appendingPathComponent("\(id)-fpm.conf")
            let ini = paths.generatedPHP.appendingPathComponent("\(id).ini")
            try AtomicFileWriter.write(try renderer.phpFPMConfiguration(runtimeID: id, sites: sites, includeManagementPool: id == "php-8.5"), to: fpmConfig)
            try AtomicFileWriter.write(try renderer.phpINI(runtimeID: id, enabledExtensions: ["redis", "imagick", "pgsql", "pdo_pgsql"], mailpitBinary: root.appendingPathComponent("mailpit-1.31.1/mailpit")), to: ini)
            let executable = root.appendingPathComponent("\(id)/sbin/php-fpm")
            _ = try runner.runChecked(executable: executable, arguments: ["-t", "-y", fpmConfig.path, "-c", ini.path])
            try await supervisor.start(ServiceSpecification(kind: ServiceKind(rawValue: id)!, executable: executable, arguments: ["--nodaemonize", "-y", fpmConfig.path, "-c", ini.path], logFile: paths.logs.appendingPathComponent("\(id).log"), readinessProbe: .fileExists(paths.phpSocket(runtimeID: id, siteID: site.id))))
            let cli = root.appendingPathComponent("\(id)/bin/php")
            let debug = try runner.runChecked(executable: cli, arguments: ["-n", "-d", "zend_extension=\(root.appendingPathComponent("\(id)/lib/php/extensions/xdebug.so").path)", "-r", "echo phpversion('xdebug');"])
            guard debug.standardOutput.contains("3.5.3") else { throw CheckFailure(message: "Xdebug did not load for \(id)") }
        }
        let apache = root.appendingPathComponent("apache-2.4/bin/httpd")
        _ = try runner.runChecked(executable: apache, arguments: ["-t", "-f", apacheConfig.path])
        try await supervisor.start(ServiceSpecification(kind: .apache, executable: apache, arguments: ["-D", "FOREGROUND", "-f", apacheConfig.path], logFile: paths.logs.appendingPathComponent("apache.log"), readinessProbe: .tcpLoopback(port: 8080)))
        let restored = ServiceSupervisor(recordsURL: paths.applicationSupport.appendingPathComponent("processes.json"))
        guard await restored.state(for: .apache).phase == .running else { throw CheckFailure(message: "Process reconciliation after app relaunch failed") }
        for site in sites { try checkSite(site, port: 8443, ca: certificates.caCertificate, runner: runner) }
        for tool in ["phpmyadmin", "adminer"] {
            let result = try request("https://\(tool).localhost:8443/", ca: certificates.caCertificate, runner: runner)
            guard result.lowercased().contains(tool) else { throw CheckFailure(message: "\(tool) did not render its login page") }
        }
        print("PASS: Apache, SSL verification, per-site PHP, extensions, phpMyAdmin and Adminer")
        await restored.stop(.apache)
        guard await restored.state(for: .apache).phase == .stopped,
              await supervisor.state(for: .mysql84).phase == .running,
              await supervisor.state(for: .php84).phase == .running else { throw CheckFailure(message: "Individual stop after relaunch failed") }
        let nginx = root.appendingPathComponent("nginx-1.30/sbin/nginx")
        let nginxArgs = ["-p", paths.generatedNginx.path + "/", "-c", nginxConfig.path]
        _ = try runner.runChecked(executable: nginx, arguments: ["-t"] + nginxArgs)
        try await supervisor.start(ServiceSpecification(kind: .nginx, executable: nginx, arguments: nginxArgs, logFile: paths.logs.appendingPathComponent("nginx.log"), readinessProbe: .tcpLoopback(port: 8443)))
        for site in sites { try checkSite(site, port: 8443, ca: certificates.caCertificate, runner: runner) }
        for tool in ["phpmyadmin", "adminer", "mailpit"] {
            let response = try request("https://\(tool).localhost:8443/", ca: certificates.caCertificate, runner: runner)
            guard response.lowercased().contains(tool) else { throw CheckFailure(message: "Nginx did not serve \(tool)") }
        }
        print("PASS: Nginx, SSL verification and both PHP versions")
        let mail = try runner.runChecked(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: ["--fail", "--silent", "--max-time", "10", "http://127.0.0.1:8025/api/v1/messages"])
        guard mail.standardOutput.contains("DevStack smoke") else { throw CheckFailure(message: "Mailpit did not receive PHP mail") }
        print("PASS: PHP mail delivery to Mailpit")
        guard await supervisor.state(for: .nginx).phase == .running, await supervisor.state(for: .mysql84).phase == .running else { throw CheckFailure(message: "Switching web servers also stopped an independent service") }
        await supervisor.stop(.postgresql18)
        guard await supervisor.state(for: .mysql84).phase == .running else { throw CheckFailure(message: "Stopping PostgreSQL stopped MySQL") }
        try await supervisor.start(postgres.specification)
        await supervisor.stop(.mysql84)
        guard await supervisor.state(for: .postgresql18).phase == .running, postgres.ping() else { throw CheckFailure(message: "Stopping MySQL stopped PostgreSQL") }
        for _ in 0..<3 {
            await supervisor.stop(.postgresql18)
            try await supervisor.start(postgres.specification)
            try expectPostgres(postgres.ping(), "Repeated PostgreSQL start/stop failed")
        }
        print("PASS: repeated start/stop, ownership reconciliation and independent MySQL/PostgreSQL stop")
    }

    static func expectPostgres(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }
    static func request(_ url: String, ca: URL, runner: ProcessRunner) throws -> String {
        try runner.runChecked(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: ["--fail", "--silent", "--show-error", "--max-time", "15", "--cacert", ca.path, url]).standardOutput
    }
    static func checkSite(_ site: SiteDefinition, port: Int, ca: URL, runner: ProcessRunner) throws {
        let response = try request("https://\(site.hostname):\(port)/", ca: ca, runner: runner)
        guard let data = response.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = json["php"] as? String, version.hasPrefix(site.phpRuntimeID.replacingOccurrences(of: "php-", with: "")),
              json["sql"] as? String == "working", json["pgsql"] as? String == "working", json["pgNative"] as? String == "working", json["mail"] as? Bool == true,
              json["png"] as? Bool == true, json["redis"] as? Bool == true, json["xdebug"] as? Bool == false else {
            throw CheckFailure(message: "PHP integration failed: \(response.prefix(1000))")
        }
    }
}
