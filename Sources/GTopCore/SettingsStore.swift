import Foundation

public final class SettingsStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
            let dir = appSupport.appendingPathComponent("GTop", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("settings.json")
        }
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return AppSettings()
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
