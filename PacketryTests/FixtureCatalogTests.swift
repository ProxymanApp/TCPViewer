import Foundation
import Testing

struct FixtureCatalogTests {

    @Test func packetryFixtureManifestExistsAndCategoriesArePresent() throws {
        #expect(FileManager.default.fileExists(atPath: PacketryFixtureCatalog.manifestURL.path))

        let manifestData = try Data(contentsOf: PacketryFixtureCatalog.manifestURL)
        #expect(!manifestData.isEmpty)

        for category in PacketryFixtureCatalog.categories {
            #expect(FileManager.default.fileExists(atPath: PacketryFixtureCatalog.captureCategoryURL(category).path))
        }
    }
}
