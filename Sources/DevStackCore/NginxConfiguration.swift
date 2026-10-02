import Foundation

extension ConfigurationRenderer {
    public func nginxConfiguration(sites: [SiteDefinition]) throws -> String {
        let root = runtimeDirectory("nginx-1.30")
        // Local network access binds every interface and restricts clients to
        // loopback and private ranges; otherwise the server stays on loopback.
        let httpHost = localNetworkAccess ? "0.0.0.0" : "127.0.0.1"
        let httpHost6 = localNetworkAccess ? "[::]" : "[::1]"
        let proxyHTTP = ports.proxyHTTPListen
        let proxyHTTPS = ports.proxyHTTPSListen
        // Extra loopback listeners receive the helper's PROXY protocol
        // connections; realip turns the forwarded address into $remote_addr.
        let httpListen = "listen \(httpHost):\(ports.webHTTPListen); listen \(httpHost6):\(ports.webHTTPListen);" + (proxyHTTP.map { "\n    listen 127.0.0.1:\($0) proxy_protocol;" } ?? "")
        let httpsListen = "listen \(httpHost):\(ports.webHTTPSListen) ssl; listen \(httpHost6):\(ports.webHTTPSListen) ssl;" + (proxyHTTPS.map { "\n    listen 127.0.0.1:\($0) ssl proxy_protocol;" } ?? "")
        let accessRules = localNetworkAccess ? """
            allow 127.0.0.1;
            allow ::1;
            allow 10.0.0.0/8;
            allow 172.16.0.0/12;
            allow 192.168.0.0/16;
            allow 169.254.0.0/16;
            allow fc00::/7;
            allow fe80::/10;
            deny all;
            """ : ""
        var servers: [String] = []
        // The default site is the first server on both ports so localhost,
        // 127.0.0.1 and unmatched hostnames never fall through to phpMyAdmin.
        if let defaultSite = sites.first(where: { $0.hostname == "localhost" }) {
            let webRoot = try nginxQuote(defaultSite.documentRoot)
            let socket = try nginxQuote("unix:" + paths.phpSocket(runtimeID: defaultSite.phpRuntimeID, siteID: defaultSite.id).path)
            let locations = """
                root \(webRoot);
                index index.php index.html;
                access_log \(try nginxQuote(defaultSite.logs.access));
                error_log \(try nginxQuote(defaultSite.logs.error));
                location / { try_files $uri $uri/ /index.php?$query_string; }
                location ~ \\.php$ {
                    try_files $uri =404;
                    include \(try nginxQuote(root.appendingPathComponent("conf/fastcgi_params").path));
                    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                    fastcgi_pass \(socket);
                }
                location ~ /\\. { deny all; }
            """
            servers.append("""
            server {
                \(httpListen)
                server_name localhost 127.0.0.1 _;
                \(locations)
            }
            server {
                \(httpsListen)
                server_name localhost 127.0.0.1 _;
                ssl_certificate \(try nginxQuote(paths.certificate(for: "localhost").path));
                ssl_certificate_key \(try nginxQuote(paths.privateKey(for: "localhost").path));
                \(locations)
            }
            """)
        }
        servers.append(contentsOf: try sites.filter { $0.hostname != "localhost" }.sorted { $0.hostname < $1.hostname }.map { site in
            _ = try HostnameValidator.validate(site.hostname)
            let hostname = site.hostname
            let webRoot = try nginxQuote(site.documentRoot)
            let socket = try nginxQuote("unix:" + paths.phpSocket(runtimeID: site.phpRuntimeID, siteID: site.id).path)
            let locations = """
                root \(webRoot);
                index index.php index.html;
                access_log \(try nginxQuote(site.logs.access));
                error_log \(try nginxQuote(site.logs.error));
                location / { try_files $uri $uri/ /index.php?$query_string; }
                location ~ \\.php$ {
                    try_files $uri =404;
                    include \(try nginxQuote(root.appendingPathComponent("conf/fastcgi_params").path));
                    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                    fastcgi_pass \(socket);
                }
                location ~ /\\. { deny all; }
            """
            if site.tlsEnabled {
                return """
                server {
                    \(httpListen)
                    server_name \(hostname);
                    return 302 https://$host\(ports.webHTTPS == 443 ? "" : ":\(ports.webHTTPS)")$request_uri;
                }
                server {
                    \(httpsListen)
                    server_name \(hostname);
                    ssl_certificate \(try nginxQuote(paths.certificate(for: hostname).path));
                    ssl_certificate_key \(try nginxQuote(paths.privateKey(for: hostname).path));
                    \(locations)
                }
                """
            }
            return """
            server {
                \(httpListen)
                server_name \(hostname);
                \(locations)
            }
            """
        })
        servers.append("""
        server {
            \(httpListen)
            server_name phpmyadmin.localhost adminer.localhost mailpit.localhost;
            return 302 https://$host\(ports.webHTTPS == 443 ? "" : ":\(ports.webHTTPS)")$request_uri;
        }
        """)
        for (host, runtimeID, pool) in [("phpmyadmin.localhost", "phpmyadmin-5.2.3", "management"), ("adminer.localhost", "adminer-6.1.1", "adminer")] {
            servers.append("""
            server {
                \(httpsListen)
                server_name \(host);
                ssl_certificate \(try nginxQuote(paths.certificate(for: host).path));
                ssl_certificate_key \(try nginxQuote(paths.privateKey(for: host).path));
                root \(try nginxQuote(host == "adminer.localhost" ? paths.generatedAdminer.path : runtimeDirectory(runtimeID).path));
                index index.php;
                location / { try_files $uri $uri/ =404; }
                location ~ \\.php$ {
                    try_files $uri =404;
                    include \(try nginxQuote(root.appendingPathComponent("conf/fastcgi_params").path));
                    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                    fastcgi_pass \(try nginxQuote("unix:" + paths.sockets.appendingPathComponent("php-8.5-\(pool).sock").path));
                }
                location ~ /\\. { deny all; }
            }
            """)
        }
        servers.append("""
        server {
            \(httpsListen)
            server_name mailpit.localhost;
            ssl_certificate \(try nginxQuote(paths.certificate(for: "mailpit.localhost").path));
            ssl_certificate_key \(try nginxQuote(paths.privateKey(for: "mailpit.localhost").path));
            location / {
                proxy_pass http://127.0.0.1:\(ports.mailpitInboxListen);
                proxy_set_header Host $host;
                proxy_set_header X-Forwarded-Proto https;
            }
        }
        """)
        return """
        worker_processes 2;
        daemon off;
        pid \(try nginxQuote(paths.generatedNginx.appendingPathComponent("nginx.pid").path));
        error_log \(try nginxQuote(paths.logs.appendingPathComponent("nginx.log").path));
        events { worker_connections 1024; }
        http {
            access_log \(try nginxQuote(paths.logs.appendingPathComponent("nginx-access.log").path));
            include \(try nginxQuote(root.appendingPathComponent("conf/mime.types").path));
            default_type application/octet-stream;
            server_tokens off;
            set_real_ip_from 127.0.0.1;
            real_ip_header proxy_protocol;
            \(accessRules)
            client_max_body_size 64m;
            ssl_protocols TLSv1.2 TLSv1.3;
            client_body_temp_path \(try nginxQuote(paths.generatedNginx.appendingPathComponent("client_temp").path));
            proxy_temp_path \(try nginxQuote(paths.generatedNginx.appendingPathComponent("proxy_temp").path));
            fastcgi_temp_path \(try nginxQuote(paths.generatedNginx.appendingPathComponent("fastcgi_temp").path));
            \(servers.joined(separator: "\n\n"))
        }
        """
    }

    private func nginxQuote(_ value: String) throws -> String {
        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw ConfigurationRendererError.unsafeValue(value)
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$") + "\""
    }
}
