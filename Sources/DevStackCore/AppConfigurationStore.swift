import Foundation

public actor AppConfigurationStore {
    private let url: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> AppConfiguration {
        guard fileManager.fileExists(atPath: url.path) else { return AppConfiguration() }
        let configuration = try decoder.decode(AppConfiguration.self, from: Data(contentsOf: url))
        guard configuration.schemaVersion <= AppConfiguration.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Configuration was created by a newer DevStack version."])
        }
        return migrate(configuration)
    }

    public func save(_ configuration: AppConfiguration) throws {
        var current = configuration
        current.schemaVersion = AppConfiguration.currentSchemaVersion
        try AtomicFileWriter.write(try encoder.encode(current), to: url)
    }

    private func migrate(_ configuration: AppConfiguration) -> AppConfiguration {
        // The Codable initializer applies the additive schema-2 database and
        // PHP-driver defaults; selection combinations and old files are checked.
        configuration
    }
}

