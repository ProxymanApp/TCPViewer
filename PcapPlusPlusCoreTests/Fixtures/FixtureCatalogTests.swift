import Foundation
import Testing

struct CoreFixtureCatalogTests {

    @Test func coreFixtureManifestExistsAndCategoriesArePresent() throws {
        #expect(FileManager.default.fileExists(atPath: CoreFixtureCatalog.manifestURL.path))

        let manifestData = try Data(contentsOf: CoreFixtureCatalog.manifestURL)
        #expect(!manifestData.isEmpty)

        for category in CoreFixtureCatalog.categories {
            #expect(FileManager.default.fileExists(atPath: CoreFixtureCatalog.captureCategoryURL(category).path))
        }
    }
}
