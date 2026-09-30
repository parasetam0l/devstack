import Foundation

extension ConfigurationRenderer {
    public func nginxConfiguration(sites: [SiteDefinition]) throws -> String {
        let root = runtimeDirectory("nginx-1.30")
        var servers = try sites.sorted { $0.hostname < $1.hostname }.map { site in
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
                    listen 127.0.0.1:8080; listen [::1]:8080;
                    server_name \(hostname);
                    return 302 https://$host\(standardPortsEnabled ? "" : ":8443")$request_uri;
                }
                server {
                    listen 127.0.0.1:8443 ssl; listen [::1]:8443 ssl;
                    server_name \(hostname);
                    ssl_certificate \(try nginxQuote(paths.certificate(for: hostname).path));
                    ssl_certificate_key \(try nginxQuote(paths.privateKey(for: hostname).path));
                    \(locations)
                }
                """
            }
            return """
            server {
                listen 127.0.0.1:8080; listen [::1]:8080;
                server_name \(hostname);
                \(locations)
            }
            """
        }
        servers.append("""
        server {
            listen 127.0.0.1:8080; listen [::1]:8080;
            server_name phpmyadmin.localhost adminer.localhost mailpit.localhost;
            return 302 https://$host\(standardPortsEnabled ? "" : ":8443")$request_uri;
        }
        """)
        for (host, runtimeID, pool) in [("phpmyadmin.localhost", "phpmyadmin-5.2.3", "management"), ("adminer.localhost", "adminer-6.1.1", "adminer")] {
            servers.append("""
            server {
                listen 127.0.0.1:8443 ssl; listen [::1]:8443 ssl;
                server_name \(host);
                ssl_certificate \(try nginxQuote(paths.certificate(for: host).path));
                ssl_certificate_key \(try nginxQuote(paths.privateKey(for: host).path));
                root \(try nginxQuote(runtimeDirectory(runtimeID).path));
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
            listen 127.0.0.1:8443 ssl; listen [::1]:8443 ssl;
            server_name mailpit.localhost;
            ssl_certificate \(try nginxQuote(paths.certificate(for: "mailpit.localhost").path));
            ssl_certificate_key \(try nginxQuote(paths.privateKey(for: "mailpit.localhost").path));
            location / {
                proxy_pass http://127.0.0.1:8025;
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
