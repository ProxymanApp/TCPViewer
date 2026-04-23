import Foundation

enum PacketryFixtureCatalog {
    static let categories = [
        "tcp",
        "udp",
        "retransmits",
        "malformed",
        "http",
        "tls",
        "dns",
        "websocket",
        "macos-metadata",
    ]

    static let repositoryRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    static let fixturesRoot = repositoryRoot.appendingPathComponent("Fixtures", isDirectory: true)
    static let manifestURL = fixturesRoot.appendingPathComponent("manifest.json")

    static func captureCategoryURL(_ category: String) -> URL {
        fixturesRoot
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent(category, isDirectory: true)
    }
}
