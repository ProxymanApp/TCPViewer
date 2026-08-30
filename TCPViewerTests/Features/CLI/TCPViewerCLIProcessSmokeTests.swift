//
//  TCPViewerCLIProcessSmokeTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct TCPViewerCLIProcessSmokeTests {
    @Test func helpAndVersionRunWithoutContactingTheApp() throws {
        let version = try run(["--version"])
        #expect(version.status == 0)
        #expect(version.output.contains(TCPViewerLicenseAppVersion.current.appVersion))

        let commands = [
            ["app", "status"], ["interfaces", "list"],
            ["capture", "status"], ["capture", "start"], ["capture", "pause"], ["capture", "resume"], ["capture", "stop"],
            ["packets", "list"], ["packets", "summary"], ["packets", "details"], ["packets", "bytes"], ["packets", "clear"], ["packets", "reveal"],
            ["stream", "packets"], ["stream", "follow"],
            ["file", "import"], ["file", "export"], ["file", "export-session"],
            ["license", "status"], ["license", "activate"], ["license", "revoke"],
            ["settings", "list"], ["settings", "get"], ["settings", "set"], ["settings", "reset"],
        ]
        for command in commands {
            let result = try run(command + ["--help"])
            #expect(result.status == 0, "Expected help to succeed for \(command.joined(separator: " "))")
            #expect(result.output.contains("USAGE:"))
        }
    }

    @Test func invalidArgumentsUseUsageExitCodeTwo() throws {
        let cases = [
            ["capture", "start"],
            ["packets", "details", "not-a-packet"],
            ["packets", "list", "--limit", "501"],
            ["packets", "list", "--scan-limit", "100001"],
            ["packets", "list", "--port", "65536"],
            ["packets", "list", "--filter", "address:equals"],
            ["packets", "list", "--filter", "source_address:equals:2001:db8::1", "--limit", "0"],
            ["packets", "details", "1", "--max-depth", "13"],
            ["packets", "details", "1", "--max-nodes", "5001"],
            ["packets", "bytes", "1", "--length", "65537"],
            ["packets", "clear"],
            ["stream", "follow", "1", "--max-bytes", "4194305"],
            ["stream", "follow", "1", "--max-records", "10001"],
            ["file", "import", "/tmp/one.tcpviewsession", "/tmp/two.pcap"],
            ["file", "export", "/tmp/export.pcapng"],
            ["file", "export", "/tmp/export.pcapng", "--all"],
            ["file", "export", "/tmp/export.pcapng", "--format", "pcapng", "--all", "--protocol", "tcp"],
            ["license", "revoke"],
            ["settings", "reset", "--all"],
            ["settings", "reset", "theme", "--all", "--yes"],
            ["app", "status", "--output", "text", "--pretty"],
            ["app", "status", "--timeout", "0"],
        ]
        for arguments in cases {
            let result = try run(arguments)
            #expect(result.status == 2, "Expected usage exit code for \(arguments.joined(separator: " "))")
            #expect(result.error.contains("Error:"))
        }
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func executableURL() throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tcpviewer-cli")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        if let products = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            let product = URL(fileURLWithPath: products).appendingPathComponent("tcpviewer-cli")
            if FileManager.default.isExecutableFile(atPath: product.path) {
                return product
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
