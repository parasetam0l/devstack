import Foundation

public enum ConfigurationRendererError: LocalizedError, Equatable, Sendable {
    case unsafeValue(String)
    case unsupportedRuntime(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeValue(let value): "Configuration value contains unsupported characters: \(value)"
        case .unsupportedRuntime(let runtime): "Unsupported runtime: \(runtime)"
        }
    }
}

public struct ConfigurationRenderer: Sendable {
    public let paths: DevStackPaths
    public let runtimeRoot: URL
    public let userName: String
    public let groupName: String

    public init(
        paths: DevStackPaths,
        runtimeRoot: URL,
        userName: String = NSUserName(),
        groupName: String = "staff"
    ) {
        self.paths = paths
        self.runtimeRoot = runtimeRoot
        self.userName = userName
        self.groupName = groupName
    }

    public func apacheConfiguration(sites: [SiteDefinition]) throws -> String {
        let apache = runtimeRoot.appendingPathComponent("apache-2.4")
        let moduleDirectory = apache.appendingPathComponent("modules")
        let siteBlocks = try sites.sorted { $0.hostname < $1.hostname }.map(apacheVirtualHost).joined(separator: "\n\n")
        let phpMyAdminCertificate = quote(paths.certificate(for: "phpmyadmin.devstack.test").path)
        let phpMyAdminKey = quote(paths.privateKey(for: "phpmyadmin.devstack.test").path)
        let mailpitCertificate = quote(paths.certificate(for: "mailpit.devstack.test").path)
        let mailpitKey = quote(paths.privateKey(for: "mailpit.devstack.test").path)
        let phpMyAdminRoot = quote(runtimeRoot.appendingPathComponent("phpmyadmin-5.2.3").path)
        let managementSocket = escapeQuotedContent(paths.sockets.appendingPathComponent("php-8.5-management.sock").path)

        return """
        ServerRoot \(quote(apache.path))
        PidFile \(quote(paths.generatedApache.appendingPathComponent("httpd.pid").path))
        ErrorLog \(quote(paths.logs.appendingPathComponent("apache-error.log").path))
        LogLevel warn
        ServerName devstack.test
        Listen 127.0.0.1:8080
        Listen 127.0.0.1:8443

        LoadModule mpm_event_module \(quote(moduleDirectory.appendingPathComponent("mod_mpm_event.so").path))
        LoadModule authz_core_module \(quote(moduleDirectory.appendingPathComponent("mod_authz_core.so").path))
        LoadModule dir_module \(quote(moduleDirectory.appendingPathComponent("mod_dir.so").path))
        LoadModule mime_module \(quote(moduleDirectory.appendingPathComponent("mod_mime.so").path))
        LoadModule log_config_module \(quote(moduleDirectory.appendingPathComponent("mod_log_config.so").path))
        LoadModule rewrite_module \(quote(moduleDirectory.appendingPathComponent("mod_rewrite.so").path))
        LoadModule ssl_module \(quote(moduleDirectory.appendingPathComponent("mod_ssl.so").path))
        LoadModule proxy_module \(quote(moduleDirectory.appendingPathComponent("mod_proxy.so").path))
        LoadModule proxy_fcgi_module \(quote(moduleDirectory.appendingPathComponent("mod_proxy_fcgi.so").path))
        LoadModule proxy_http_module \(quote(moduleDirectory.appendingPathComponent("mod_proxy_http.so").path))
        LoadModule headers_module \(quote(moduleDirectory.appendingPathComponent("mod_headers.so").path))

        TypesConfig \(quote(apache.appendingPathComponent("conf/mime.types").path))
        DirectoryIndex index.php index.html
        EnableSendfile Off
        TraceEnable Off
        ServerTokens Prod
        ServerSignature Off

        <Directory />
            AllowOverride None
            Require all denied
        </Directory>

        \(siteBlocks)

        <VirtualHost 127.0.0.1:8443>
            ServerName phpmyadmin.devstack.test
            DocumentRoot \(phpMyAdminRoot)
            SSLEngine on
            SSLCertificateFile \(phpMyAdminCertificate)
            SSLCertificateKeyFile \(phpMyAdminKey)
            <Directory \(phpMyAdminRoot)>
                Options FollowSymLinks
                AllowOverride None
                Require local
                <FilesMatch "\\.php$">
                    SetHandler "proxy:unix:\(managementSocket)|fcgi://localhost/"
                </FilesMatch>
            </Directory>
        </VirtualHost>

        <VirtualHost 127.0.0.1:8443>
            ServerName mailpit.devstack.test
            SSLEngine on
            SSLCertificateFile \(mailpitCertificate)
            SSLCertificateKeyFile \(mailpitKey)
            ProxyPreserveHost On
            ProxyPass / http://127.0.0.1:8025/
            ProxyPassReverse / http://127.0.0.1:8025/
            RequestHeader set X-Forwarded-Proto "https"
        </VirtualHost>
        """
    }

    public func phpFPMConfiguration(runtimeID: String, sites: [SiteDefinition], includeManagementPool: Bool = false) throws -> String {
        guard runtimeID == "php-7.4" || runtimeID == "php-8.5" else {
            throw ConfigurationRendererError.unsupportedRuntime(runtimeID)
        }
        var pools = try sites
            .filter { $0.phpRuntimeID == runtimeID }
            .sorted { $0.hostname < $1.hostname }
            .map(phpPool)
        if includeManagementPool && runtimeID == "php-8.5" {
            let root = runtimeRoot.appendingPathComponent("phpmyadmin-5.2.3").path
            pools.append(try managementPool(documentRoot: root))
        }

        return """
        [global]
        pid = \(quote(paths.generatedPHP.appendingPathComponent("\(runtimeID).pid").path))
        error_log = \(quote(paths.logs.appendingPathComponent("\(runtimeID)-fpm.log").path))
        daemonize = no
        events.mechanism = kqueue

        \(pools.joined(separator: "\n\n"))
        """
    }

    public func phpINI(runtimeID: String, enabledExtensions: Set<String>, mailpitBinary: URL) throws -> String {
        guard runtimeID == "php-7.4" || runtimeID == "php-8.5" else {
            throw ConfigurationRendererError.unsupportedRuntime(runtimeID)
        }
        let runtime = runtimeRoot.appendingPathComponent(runtimeID)
        let extensionDirectory = runtime.appendingPathComponent("lib/php/extensions")
        let extensionLines = enabledExtensions.sorted().map { name in
            let directive = name == "xdebug" ? "zend_extension" : "extension"
            return "\(directive)=\(quote(extensionDirectory.appendingPathComponent("\(name).so").path))"
        }

        return """
        [PHP]
        engine=On
        short_open_tag=Off
        expose_php=Off
        display_errors=On
        log_errors=On
        error_log=\(quote(paths.logs.appendingPathComponent("\(runtimeID)-php.log").path))
        date.timezone=UTC
        memory_limit=256M
        max_execution_time=120
        post_max_size=64M
        upload_max_filesize=64M
        extension_dir=\(quote(extensionDirectory.path))
        sendmail_path=\(quote("\(mailpitBinary.path) sendmail -S 127.0.0.1:1025"))
        mysqli.default_port=3306
        mysqli.default_socket=\(quote(paths.sockets.appendingPathComponent("mysql.sock").path))
        pdo_mysql.default_socket=\(quote(paths.sockets.appendingPathComponent("mysql.sock").path))
        opcache.enable=1
        opcache.enable_cli=0

        \(extensionLines.joined(separator: "\n"))
        """
    }

    public func mysqlConfiguration(engine: DatabaseEngine, baseDirectory: URL) -> String {
        let dataDirectory = engine == .mysql57 ? paths.mysql57Data : paths.mysql84Data
        let suffix = engine.rawValue
        return """
        [client]
        port=3306
        socket=\(paths.sockets.appendingPathComponent("mysql.sock").path)

        [mysqld]
        basedir=\(baseDirectory.path)
        datadir=\(dataDirectory.path)
        port=3306
        bind-address=127.0.0.1
        socket=\(paths.sockets.appendingPathComponent("mysql.sock").path)
        pid-file=\(paths.generated.appendingPathComponent("\(suffix).pid").path)
        log-error=\(paths.logs.appendingPathComponent("\(suffix).log").path)
        local-infile=0
        symbolic-links=0
        secure-file-priv=NULL
        max_allowed_packet=64M
        \(engine == .mysql84 ? "mysqlx=0" : "")
        """
    }

    public func mailpitArguments() -> [String] {
        [
            "--listen", "127.0.0.1:8025",
            "--smtp", "127.0.0.1:1025",
            "--database", paths.mailpitDatabase.path,
            "--allowed-hosts", "127.0.0.1,localhost,mailpit.devstack.test",
            "--max", "5000"
        ]
    }

    public func composerWrapperScript() -> String {
        let php = runtimeRoot.appendingPathComponent("php-8.5/bin/php").path
        let ini = paths.generatedPHP.appendingPathComponent("php-8.5.ini").path
        let phar = runtimeRoot.appendingPathComponent("composer-2.10.3/composer.phar").path
        return """
        #!/bin/sh
        # DevStack-managed Composer wrapper. The bundled Composer phar is immutable.
        case "${1:-}" in
            self-update|selfupdate)
                echo "Composer self-update is disabled in DevStack. Update Composer through a signed DevStack release." >&2
                exit 64
                ;;
        esac
        exec \(shellQuote(php)) -c \(shellQuote(ini)) \(shellQuote(phar)) "$@"
        """
    }

    private func apacheVirtualHost(_ site: SiteDefinition) throws -> String {
        _ = try HostnameValidator.validate(site.hostname)
        try requireSafe(site.documentRoot)
        let hostname = site.hostname
        let root = quote(site.documentRoot)
        let socket = escapeQuotedContent(paths.phpSocket(runtimeID: site.phpRuntimeID, siteID: site.id).path)
        let accessLog = quote(site.logs.access)
        let errorLog = quote(site.logs.error)
        let directory = """
            <Directory \(root)>
                Options FollowSymLinks
                AllowOverride All
                Require local
                <FilesMatch "\\.php$">
                    SetHandler "proxy:unix:\(socket)|fcgi://localhost/"
                </FilesMatch>
            </Directory>
        """

        let httpBehavior = site.tlsEnabled
            ? "Redirect permanent / https://\(hostname)/"
            : "DocumentRoot \(root)\n\(directory)"

        var result = """
        <VirtualHost 127.0.0.1:8080>
            ServerName \(hostname)
            ErrorLog \(errorLog)
            CustomLog \(accessLog) combined
            \(httpBehavior)
        </VirtualHost>
        """

        if site.tlsEnabled {
            result += """

            <VirtualHost 127.0.0.1:8443>
                ServerName \(hostname)
                DocumentRoot \(root)
                ErrorLog \(errorLog)
                CustomLog \(accessLog) combined
                SSLEngine on
                SSLCertificateFile \(quote(paths.certificate(for: hostname).path))
                SSLCertificateKeyFile \(quote(paths.privateKey(for: hostname).path))
                Header always set X-Content-Type-Options "nosniff"
                \(directory)
            </VirtualHost>
            """
        }
        return result
    }

    private func phpPool(_ site: SiteDefinition) throws -> String {
        try requireSafe(site.documentRoot)
        let poolName = "site_\(site.id.uuidString.replacingOccurrences(of: "-", with: "_").lowercased())"
        return """
        [\(poolName)]
        user = \(userName)
        group = \(groupName)
        listen = \(paths.phpSocket(runtimeID: site.phpRuntimeID, siteID: site.id).path)
        listen.owner = \(userName)
        listen.group = \(groupName)
        listen.mode = 0600
        pm = ondemand
        pm.max_children = 8
        pm.process_idle_timeout = 10s
        catch_workers_output = yes
        chdir = \(site.documentRoot)
        php_admin_value[display_errors] = \(site.phpOverrides.displayErrors ? "On" : "Off")
        php_admin_value[memory_limit] = \(site.phpOverrides.memoryLimit)
        php_admin_value[max_execution_time] = \(site.phpOverrides.maxExecutionTime)
        php_admin_value[upload_max_filesize] = \(site.phpOverrides.uploadMaxFilesize)
        php_admin_value[post_max_size] = \(site.phpOverrides.postMaxSize)
        php_admin_value[max_input_vars] = \(site.phpOverrides.maxInputVars)
        php_admin_value[error_log] = \(site.logs.error)
        """
    }

    private func managementPool(documentRoot: String) throws -> String {
        try requireSafe(documentRoot)
        return """
        [management]
        user = \(userName)
        group = \(groupName)
        listen = \(paths.sockets.appendingPathComponent("php-8.5-management.sock").path)
        listen.owner = \(userName)
        listen.group = \(groupName)
        listen.mode = 0600
        pm = ondemand
        pm.max_children = 4
        chdir = \(documentRoot)
        php_admin_value[display_errors] = Off
        php_admin_value[memory_limit] = 256M
        """
    }

    private func quote(_ value: String) -> String {
        "\"\(escapeQuotedContent(value))\""
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func escapeQuotedContent(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func requireSafe(_ value: String) throws {
        if value.contains("\n") || value.contains("\r") || value.contains("\0") {
            throw ConfigurationRendererError.unsafeValue(value)
        }
    }
}
