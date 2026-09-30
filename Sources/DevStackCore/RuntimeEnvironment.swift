import Foundation

public enum RuntimeEnvironment {
    public static func services(openssl: URL, imageMagick: URL, phpConfiguration: URL) -> [String: String] {
        self.openssl(at: openssl).merging([
            "MAGICK_CONFIGURE_PATH": imageMagick.appendingPathComponent("etc/ImageMagick-7").path + ":" + imageMagick.appendingPathComponent("share/ImageMagick-7").path,
            "MAGICK_HOME": imageMagick.path,
            "DEVSTACK_MAGICK_CONFIG_ONLY": "1",
            "PHP_INI_SCAN_DIR": phpConfiguration.appendingPathComponent("conf.d").path
        ]) { _, new in new }
    }
    /// OpenSSL embeds its build prefix. Always provide the installed config and providers.
    public static func openssl(at runtime: URL) -> [String: String] {
        ["OPENSSL_CONF": runtime.appendingPathComponent("ssl/openssl.cnf").path,
         "OPENSSL_MODULES": runtime.appendingPathComponent("lib/ossl-modules").path,
         "SSL_CERT_DIR": runtime.appendingPathComponent("ssl/certs").path,
         "SSL_CERT_FILE": runtime.appendingPathComponent("ssl/cert.pem").path]
    }
}
