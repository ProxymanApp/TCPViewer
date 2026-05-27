//
//  FixtureCatalogTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

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
