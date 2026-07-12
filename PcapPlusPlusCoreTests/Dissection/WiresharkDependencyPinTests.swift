//
//  WiresharkDependencyPinTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 12/7/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkDependencyPinTests {
    private let expectedTag = "v4.6.6"
    private let expectedCommit = "3a22c3ef473d3f9c556d1fb13e3088c693d4fa96"

    @Test func publishedPinUsesPatchedWiresharkRelease() {
        #expect(PcapPlusPlusCoreModule.wiresharkPinnedTag == expectedTag)
        #expect(PcapPlusPlusCoreModule.wiresharkPinnedCommit == expectedCommit)
    }

    @Test func buildAndNoticeMetadataMatchPublishedPin() throws {
        let bootstrap = try contents(of: "scripts/bootstrap-wireshark.sh")
        let notices = try contents(of: "THIRD_PARTY_NOTICES.md")
        let cmake = try contents(of: "Vendor/Wireshark/CMakeLists.txt")

        #expect(bootstrap.contains("PINNED_TAG=\"\(expectedTag)\""))
        #expect(bootstrap.contains("PINNED_COMMIT=\"\(expectedCommit)\""))
        #expect(notices.contains("Pinned tag: `\(expectedTag)`"))
        #expect(notices.contains("Pinned peeled commit: `\(expectedCommit)`"))
        #expect(cmake.contains("set(PROJECT_MAJOR_VERSION 4)"))
        #expect(cmake.contains("set(PROJECT_MINOR_VERSION 6)"))
        #expect(cmake.contains("set(PROJECT_PATCH_VERSION 6)"))
    }

    @Test func vendoredCheckoutMatchesPinnedCommit() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryRoot.appendingPathComponent("Vendor/Wireshark").path, "rev-parse", "HEAD"]
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let commit = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(process.terminationStatus == 0)
        #expect(commit == expectedCommit)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
