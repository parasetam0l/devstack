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
    public let runtimeDirectories: [String: URL]
    public let ports: ServicePorts
    public let userName: String
    public let groupName: String

    public init(
        paths: DevStackPaths,
        runtimeRoot: URL,
        runtimeDirectories: [String: URL] = [:],
        ports: ServicePorts = ServicePorts(),
        userName: String = NSUserName(),
        groupName: String = "staff"
    ) {
        self.paths = paths
        self.runtimeRoot = runtimeRoot
        self.runtimeDirectories = runtimeDirectories
        self.ports = ports
        self.userName = userName
        self.groupName = groupName
    }

    public func apacheConfiguration(sites: [SiteDefinition]) throws -> String {
        let apache = runtimeDirectory("apache-2.4")
        let moduleDirectory = apache.appendingPathComponent("modules")
        let mpm = moduleDirectory.appendingPathComponent("mod_mpm_event.so")
        let mpmDirective = FileManager.default.fileExists(atPath: mpm.path) ? "LoadModule mpm_event_module \(quote(mpm.path))" : ""
        let siteBlocks = try sites.sorted { $0.hostname < $1.hostname }.map(apacheVirtualHost).joined(separator: "\n\n")
        let phpMyAdminCertificate = quote(paths.certificate(for: "phpmyadmin.localhost").path)
        let phpMyAdminKey = quote(paths.privateKey(for: "phpmyadmin.localhost").path)
        let mailpitCertificate = quote(paths.certificate(for: "mailpit.localhost").path)
        let mailpitKey = quote(paths.privateKey(for: "mailpit.localhost").path)
        let phpMyAdminRoot = quote(runtimeDirectory("phpmyadmin-5.2.3").path)
        let managementSocket = escapeQuotedContent(paths.sockets.appendingPathComponent("php-8.5-management.sock").path)

        return """
        ServerRoot \(quote(apache.path))
        PidFile \(quote(paths.generatedApache.appendingPathComponent("httpd.pid").path))
        ErrorLog \(quote(paths.logs.appendingPathComponent("apache-error.log").path))
        LogLevel warn
        ServerName devstack.test
        Listen 127.0.0.1:\(ports.webHTTPListen)
        Listen 127.0.0.1:\(ports.webHTTPSListen)
        Listen [::1]:\(ports.webHTTPListen)
        Listen [::1]:\(ports.webHTTPSListen)

        \(mpmDirective)
        LoadModule unixd_module \(quote(moduleDirectory.appendingPathComponent("mod_unixd.so").path))
        LoadModule authz_host_module \(quote(moduleDirectory.appendingPathComponent("mod_authz_host.so").path))
        LoadModule alias_module \(quote(moduleDirectory.appendingPathComponent("mod_alias.so").path))
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

        <VirtualHost *:\(ports.webHTTPSListen)>
            ServerName phpmyadmin.localhost
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

        <VirtualHost *:\(ports.webHTTPSListen)>
            ServerName adminer.localhost
            DocumentRoot \(quote(runtimeDirectory("adminer-6.1.1").path))
            SSLEngine on
            SSLCertificateFile \(quote(paths.certificate(for: "adminer.localhost").path))
            SSLCertificateKeyFile \(quote(paths.privateKey(for: "adminer.localhost").path))
            <Directory \(quote(runtimeDirectory("adminer-6.1.1").path))>
                AllowOverride None
                Require local
                <FilesMatch "\\.php$">
                    SetHandler "proxy:unix:\(escapeQuotedContent(paths.sockets.appendingPathComponent("php-8.5-adminer.sock").path))|fcgi://localhost/"
                </FilesMatch>
            </Directory>
        </VirtualHost>

        <VirtualHost *:\(ports.webHTTPSListen)>
            ServerName mailpit.localhost
            SSLEngine on
            SSLCertificateFile \(mailpitCertificate)
            SSLCertificateKeyFile \(mailpitKey)
            ProxyPreserveHost On
            ProxyPass / http://127.0.0.1:\(ports.mailpitInboxListen)/
            ProxyPassReverse / http://127.0.0.1:\(ports.mailpitInboxListen)/
            RequestHeader set X-Forwarded-Proto "https"
        </VirtualHost>
        """
    }

    public func phpFPMConfiguration(runtimeID: String, sites: [SiteDefinition], includeManagementPool: Bool = false) throws -> String {
        guard ["php-7.4", "php-8.4", "php-8.5"].contains(runtimeID) else {
            throw ConfigurationRendererError.unsupportedRuntime(runtimeID)
        }
        var pools = try sites
            .filter { $0.phpRuntimeID == runtimeID }
            .sorted { $0.hostname < $1.hostname }
            .map(phpPool)
        if pools.isEmpty && runtimeID != "php-8.5" {
            pools.append("""
            [default]
            \(try phpPoolEnvironment())
            user = \(userName)
            group = \(groupName)
            listen = \(paths.sockets.appendingPathComponent("\(runtimeID)-default.sock").path)
            listen.mode = 0600
            pm = ondemand
            pm.max_children = 4
            """)
        }
        if includeManagementPool && runtimeID == "php-8.5" {
            let root = runtimeDirectory("phpmyadmin-5.2.3").path
            pools.append(try managementPool(documentRoot: root))
            pools.append(try adminerPool())
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
        guard ["php-7.4", "php-8.4", "php-8.5"].contains(runtimeID) else {
            throw ConfigurationRendererError.unsupportedRuntime(runtimeID)
        }
        let runtime = runtimeDirectory(runtimeID)
        let extensionDirectory = runtime.appendingPathComponent("lib/php/extensions")
        guard enabledExtensions.isSubset(of: ["xdebug", "redis", "imagick", "pgsql", "pdo_pgsql"]) else {
            throw ConfigurationRendererError.unsafeValue("Unknown PHP extension")
        }
        var settings = enabledExtensions.sorted().map { name in
            let directive = name == "xdebug" ? "zend_extension" : "extension"
            return "\(directive)=\(quote(extensionDirectory.appendingPathComponent("\(name).so").path))"
        }
        if enabledExtensions.contains("xdebug") {
            settings.append(contentsOf: [
                "xdebug.mode=debug",
                "xdebug.client_host=127.0.0.1",
                "xdebug.client_port=9003"
            ])
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
        openssl.cafile=\(quote(paths.certificates.appendingPathComponent("trusted-roots.pem").path))
        curl.cainfo=\(quote(paths.certificates.appendingPathComponent("trusted-roots.pem").path))
        memory_limit=256M
        max_execution_time=120
        post_max_size=64M
        upload_max_filesize=64M
        extension_dir=\(quote(extensionDirectory.path))
        sendmail_path=\(quote("\(mailpitBinary.path) sendmail -S 127.0.0.1:\(ports.mailpitSMTPListen)"))
        mysqli.default_port=\(ports.mysqlListen)
        mysqli.default_socket=\(quote(paths.sockets.appendingPathComponent("mysql.sock").path))
        pdo_mysql.default_socket=\(quote(paths.sockets.appendingPathComponent("mysql.sock").path))
        opcache.enable=1
        opcache.enable_cli=0
        opcache.jit=disable
        opcache.jit_buffer_size=0

        \(settings.joined(separator: "\n"))
        """
    }

    public func mysqlConfiguration(engine: DatabaseEngine, baseDirectory: URL) -> String {
        let dataDirectory = engine == .mysql57 ? paths.mysql57Data : paths.mysql84Data
        let suffix = engine.rawValue
        return """
        [client]
        port=\(ports.mysqlListen)
        character-sets-dir=\(baseDirectory.appendingPathComponent("share/charsets").path)
        socket=\(paths.sockets.appendingPathComponent("mysql.sock").path)

        [mysqld]
        basedir=\(baseDirectory.path)
        plugin-dir=\(baseDirectory.appendingPathComponent("lib/plugin").path)
        datadir=\(dataDirectory.path)
        port=\(ports.mysqlListen)
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
            "--listen", "127.0.0.1:\(ports.mailpitInboxListen)",
            "--smtp", "127.0.0.1:\(ports.mailpitSMTPListen)",
            "--database", paths.mailpitDatabase.path,
            "--allowed-hosts", "127.0.0.1,localhost,mailpit.localhost",
            "--disable-version-check",
            "--max", "5000"
        ]
    }

    public func databaseClientWrapperScript(engine: DatabaseEngine, client: String) throws -> String {
        guard ["mysql", "mysqldump", "mysqladmin"].contains(client) else {
            throw ConfigurationRendererError.unsafeValue(client)
        }
        let base = runtimeDirectory(engine.rawValue)
        let environment = RuntimeEnvironment.openssl(at: runtimeDirectory("openssl-3.5"))
            .map { "export \($0.key)=\(shellQuote($0.value))" }.sorted().joined(separator: "\n")
        return """
        #!/bin/sh
        \(environment)
        exec \(shellQuote(base.appendingPathComponent("bin/\(client)").path)) --no-defaults --no-login-paths --character-sets-dir=\(shellQuote(base.appendingPathComponent("share/charsets").path)) --plugin-dir=\(shellQuote(base.appendingPathComponent("lib/plugin").path)) --socket=\(shellQuote(paths.sockets.appendingPathComponent("mysql.sock").path)) "$@"
        """
    }

    public func composerWrapperScript(runtimeID: String = "php-8.5") -> String {
        let php = runtimeDirectory(runtimeID).appendingPathComponent("bin/php").path
        let ini = paths.generatedPHP.appendingPathComponent("\(runtimeID).ini").path
        let phar = runtimeDirectory("composer-2.10.3").appendingPathComponent("composer.phar").path
        let environment = RuntimeEnvironment.services(openssl: runtimeDirectory("openssl-3.5"),
            imageMagick: runtimeDirectory("imagemagick-7.1"), phpConfiguration: paths.generatedPHP)
            .map { "export \($0.key)=\(shellQuote($0.value))" }.sorted().joined(separator: "\n")
        return """
        #!/bin/sh
        # DevStack-managed Composer wrapper. The bundled Composer phar is immutable.
        \(environment)
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
            ? "Redirect permanent / https://\(hostname)\(ports.webHTTPS == 443 ? "" : ":\(ports.webHTTPS)")/"
            : "DocumentRoot \(root)\n\(directory)"

        var result = """
        <VirtualHost *:\(ports.webHTTPListen)>
            ServerName \(hostname)
            ErrorLog \(errorLog)
            CustomLog \(accessLog) combined
            \(httpBehavior)
        </VirtualHost>
        """

        if site.tlsEnabled {
            result += """

            <VirtualHost *:\(ports.webHTTPSListen)>
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
        for value in [site.phpOverrides.memoryLimit, site.phpOverrides.uploadMaxFilesize, site.phpOverrides.postMaxSize] {
            guard value.range(of: "^[1-9][0-9]*[KMG]?$", options: .regularExpression) != nil else {
                throw ConfigurationRendererError.unsafeValue(value)
            }
        }
        guard site.phpOverrides.maxExecutionTime >= 0, site.phpOverrides.maxInputVars > 0 else {
            throw ConfigurationRendererError.unsafeValue("PHP request limits")
        }
        let poolName = "site_\(site.id.uuidString.replacingOccurrences(of: "-", with: "_").lowercased())"
        return """
        [\(poolName)]
        \(try phpPoolEnvironment())
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
        \(try phpPoolEnvironment())
        user = \(userName)
        group = \(groupName)
        listen = \(paths.sockets.appendingPathComponent("php-8.5-management.sock").path)
        listen.owner = \(userName)
        listen.group = \(groupName)
        listen.mode = 0600
        pm = ondemand
        pm.max_children = 4
        chdir = \(documentRoot)
        env[DEVSTACK_PHPMYADMIN_CONFIG] = \(quote(paths.phpMyAdmin.appendingPathComponent("config.inc.php").path))
        env[DEVSTACK_PHPMYADMIN_TEMP] = \(quote(paths.phpMyAdmin.appendingPathComponent("tmp").path + "/"))
        php_admin_value[display_errors] = Off
        php_admin_value[memory_limit] = 256M
        """
    }

    public func phpMyAdminConfiguration(cookieSecret: String) throws -> String {
        guard cookieSecret.count == 32, cookieSecret.allSatisfy({ $0.isLetter || $0.isNumber || "+/".contains($0) }) else {
            throw ConfigurationRendererError.unsafeValue("Invalid phpMyAdmin cookie secret")
        }
        return """
        <?php
        $cfg['blowfish_secret'] = '\(cookieSecret)';
        $cfg['Servers'][1]['auth_type'] = 'cookie';
        $cfg['Servers'][1]['host'] = '127.0.0.1';
        $cfg['Servers'][1]['port'] = '\(ports.mysqlListen)';
        $cfg['Servers'][1]['AllowNoPassword'] = false;
        $cfg['VersionCheck'] = false;
        """
    }

    public func runtimeDirectory(_ id: String) -> URL {
        runtimeDirectories[id] ?? runtimeRoot.appendingPathComponent(id)
    }

    private func adminerPool() throws -> String {
        let socket = paths.sockets.appendingPathComponent("php-8.5-adminer.sock").path
        return """
        [adminer]
        \(try phpPoolEnvironment())
        user = \(userName)
        group = \(groupName)
        listen = \(socket)
        listen.mode = 0600
        pm = ondemand
        pm.max_children = 4
        chdir = \(runtimeDirectory("adminer-6.1.1").path)
        php_admin_value[display_errors] = Off
        """
    }

    private func phpPoolEnvironment() throws -> String {
        try RuntimeEnvironment.services(openssl: runtimeDirectory("openssl-3.5"),
            imageMagick: runtimeDirectory("imagemagick-7.1"), phpConfiguration: paths.generatedPHP)
            .sorted { $0.key < $1.key }.map { key, value in
                try requireSafe(value)
                return "env[\(key)] = \(quote(value))"
            }.joined(separator: "\n")
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
