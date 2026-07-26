//
//  TCPViewerMCPCommandRouterTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Darwin
import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
@MainActor
struct TCPViewerMCPCommandRouterTests {
    @Test func everyActionIsCoveredWithSensitiveModeOnAndOff() async throws {
        for redactionEnabled in [true, false] {
            let source = TCPViewerMCPFakeDataSource()
            let router = makeRouter(source: source, redactsSensitiveData: { redactionEnabled })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerMCPAllActions-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let responses = await [
                routeMCP(router, command: .getAppStatus),
                routeMCP(router, command: .getCaptureOverview),
                routeMCP(router, command: .listInterfaces),
                routeMCP(router, command: .queryPackets),
                routeMCP(router, command: .summarizeCapture),
                routeMCP(router, command: .getPacketDetails, params: ["packet_id": .string("1")]),
                routeMCP(router, command: .listStreamPackets, params: ["stream_id": .int(7)]),
                routeMCP(router, command: .exportPackets, params: [
                    "path": .string(directory.appendingPathComponent("mode-\(redactionEnabled).pcapng").path),
                    "all": .bool(true),
                ]),
                routeMCP(router, command: .startCapture),
                routeMCP(router, command: .pauseCapture),
                routeMCP(router, command: .resumeCapture),
                routeMCP(router, command: .stopCapture),
                routeMCP(router, command: .revealPacket, params: ["packet_id": .string("1")]),
            ]
            #expect(responses.allSatisfy { $0.success })

            let bytes = await routeMCP(router, command: .getPacketBytes, params: ["packet_id": .string("1")])
            #expect(bytes.success == !redactionEnabled)

            let clear = await routeMCP(router, command: .clearPackets, params: ["confirm": .bool(true)])
            #expect(clear.success)
        }
    }

    @Test func routesEveryReadActionWithRedactionEnabled() async throws {
        let source = TCPViewerMCPFakeDataSource()
        let router = makeRouter(source: source, redactsSensitiveData: { true })

        let status = await routeMCP(router, command: .getAppStatus)
        #expect(status.success)
        #expect(status.value("app") == .string("TCP Viewer"))
        #expect(status.value("redaction_enabled") == .bool(true))

        let overview = await routeMCP(router, command: .getCaptureOverview)
        #expect(overview.value("packet_count") == .int(2))
        #expect(overview.value("dropped_packet_count") == .string("3"))
        #expect(overview.value("capture_filter_language") == .string("libpcap_bpf"))

        let interfaces = await routeMCP(router, command: .listInterfaces)
        #expect(interfaces.value("count") == .int(1))
        #expect(interfaces.value("interfaces")?.arrayValue?.first?.objectValue?["id"] == .string("en0"))

        let packets = await routeMCP(router, command: .queryPackets, params: [
            "protocols": .array([.string("TLS")]),
        ])
        let packet = packets.value("packets")?.arrayValue?.first?.objectValue
        #expect(packet?["id"] == .string("1"))
        #expect(packet?["info"] == .string("Authorization: <redacted>"))

        let boundedPackets = await routeMCP(router, command: .queryPackets, params: [
            "order": .string("oldest"),
            "scan_limit": .int(1),
        ])
        #expect(boundedPackets.value("scanned_count") == .int(1))
        #expect(boundedPackets.value("total_packet_count") == .int(2))
        #expect(boundedPackets.value("next_scan_offset") == .int(1))
        #expect(boundedPackets.value("has_more_unscanned_packets") == .bool(true))

        let nextWindow = await routeMCP(router, command: .queryPackets, params: [
            "order": .string("oldest"),
            "scan_limit": .int(1),
            "scan_offset": .int(1),
        ])
        #expect(nextWindow.value("packets")?.arrayValue?.first?.objectValue?["id"] == .string("2"))
        #expect(nextWindow.value("next_scan_offset") == .null)
        #expect(nextWindow.value("has_more_unscanned_packets") == .bool(false))

        let summary = await routeMCP(router, command: .summarizeCapture)
        #expect(summary.value("matched_packet_count") == .int(2))
        #expect(summary.value("captured_byte_count") == .int(256))

        let details = await routeMCP(router, command: .getPacketDetails, params: ["packet_id": .string("1")])
        let root = details.value("packet")?.objectValue?["detail_nodes"]?.arrayValue?.first?.objectValue
        #expect(root?["value"] == .string(TCPViewerMCPSensitiveDataRedactor.placeholder))

        let stream = await routeMCP(router, command: .listStreamPackets, params: ["stream_id": .int(7)])
        #expect(stream.value("returned_count") == .int(2))

        let rawBytes = await routeMCP(router, command: .getPacketBytes, params: ["packet_id": .string("1")])
        #expect(!rawBytes.success)
        #expect(rawBytes.error?.contains("redaction is enabled") == true)
    }

    @Test func rawBytesAndUnredactedDetailsAreAvailableOnlyWhenPrivacyIsOff() async {
        let source = TCPViewerMCPFakeDataSource()
        let router = makeRouter(source: source, redactsSensitiveData: { false })

        let bytes = await routeMCP(router, command: .getPacketBytes, params: [
            "packet_id": .string("1"),
            "offset": .int(1),
            "length": .int(3),
            "encoding": .string("base64"),
        ])
        #expect(bytes.success)
        #expect(bytes.value("bytes")?.objectValue?["data"] == .string("AgME"))

        let details = await routeMCP(router, command: .getPacketDetails, params: ["packet_id": .int(1)])
        let root = details.value("packet")?.objectValue?["detail_nodes"]?.arrayValue?.first?.objectValue
        #expect(root?["value"] == .string("Bearer super-secret-token"))

        let query = await routeMCP(router, command: .queryPackets)
        #expect(query.value("packets")?.arrayValue?.first?.objectValue?["info"] == .string("Authorization: Bearer secret-value"))
    }

    @Test func rawBytesFailClosedWhenPrivacyIsEnabledDuringInspection() async {
        let source = TCPViewerMCPFakeDataSource()
        var redactionEnabled = false
        let router = makeRouter(source: source, redactsSensitiveData: { redactionEnabled })

        let response = await withCheckedContinuation { continuation in
            router.route(TCPViewerMCPRequest(
                command: TCPViewerMCPCommand.getPacketBytes.rawValue,
                params: ["packet_id": .string("1")]
            )) { response in
                continuation.resume(returning: response)
            }
            redactionEnabled = true
        }

        #expect(!response.success)
        #expect(response.error?.contains("redaction is enabled") == true)
    }

    @Test func routesExportCaptureControlsRevealAndClearActions() async throws {
        let source = TCPViewerMCPFakeDataSource()
        let router = makeRouter(source: source, redactsSensitiveData: { true })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerMCPRouter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let export = await routeMCP(router, command: .exportPackets, params: [
            "path": .string(directory.appendingPathComponent("selection").path),
            "format": .string("pcapng"),
            "packet_ids": .array([.string("1")]),
        ])
        #expect(export.success)
        #expect(source.exportedIDs == [1])
        #expect(source.exportedURL?.pathExtension == "pcapng")
        #expect(source.exportedFormat == .pcapng)

        let start = await routeMCP(router, command: .startCapture, params: [
            "interface_id": .string("en0"),
            "capture_filter": .string("tcp port 443"),
            "confirm_bpf_filter": .bool(true),
        ])
        let pause = await routeMCP(router, command: .pauseCapture)
        let resume = await routeMCP(router, command: .resumeCapture)
        let stop = await routeMCP(router, command: .stopCapture)
        #expect([start, pause, resume, stop].allSatisfy { $0.success })
        #expect(source.startedInterfaceID == "en0")
        #expect(source.startedCaptureFilter == "tcp port 443")
        #expect(start.value("previous_packets_cleared") == .bool(true))
        #expect(start.value("bpf_capture_filter_action") == .string("set"))
        #expect(source.paused && source.resumed && source.stopped)

        let reveal = await routeMCP(router, command: .revealPacket, params: ["packet_id": .string("2")])
        #expect(reveal.success)
        #expect(source.revealedPacketID == 2)

        let unconfirmedClear = await routeMCP(router, command: .clearPackets)
        #expect(!unconfirmedClear.success)
        #expect(!source.cleared)

        let clear = await routeMCP(router, command: .clearPackets, params: ["confirm": .bool(true)])
        #expect(clear.value("cleared_packet_count") == .int(2))
        #expect(source.cleared)
    }

    @Test func startCaptureRequiresExplicitConfirmationForNonemptyBPFFilter() async {
        let source = TCPViewerMCPFakeDataSource()
        let router = makeRouter(source: source, redactsSensitiveData: { false })

        let unconfirmed = await routeMCP(router, command: .startCapture, params: [
            "capture_filter": .string("host 1.1.1.1 and port 443"),
        ])
        #expect(!unconfirmed.success)
        #expect(unconfirmed.error?.contains("persistent BPF capture filter") == true)
        #expect(unconfirmed.error?.contains("query_packets") == true)
        #expect(source.startedCaptureFilter == nil)

        let clear = await routeMCP(router, command: .startCapture, params: [
            "capture_filter": .string(""),
        ])
        #expect(clear.success)
        #expect(source.startedCaptureFilter == "")
        #expect(clear.value("bpf_capture_filter_action") == .string("cleared"))
    }

    @Test func rejectsUnauthorizedUnknownUnavailableAndInvalidRequests() async {
        let source = TCPViewerMCPFakeDataSource()
        let unauthorized = TCPViewerMCPCommandRouter(
            dataSourceProvider: { source },
            isLicenseAuthorized: { false },
            redactionEnabled: { true }
        )
        #expect(!(await routeMCP(unauthorized, command: .getAppStatus)).success)

        let unavailable = TCPViewerMCPCommandRouter(
            dataSourceProvider: { nil },
            isLicenseAuthorized: { true },
            redactionEnabled: { true }
        )
        #expect(!(await routeMCP(unavailable, command: .queryPackets)).success)

        let router = makeRouter(source: source, redactsSensitiveData: { false })
        let unknown = await routeRaw(router, command: "made_up")
        #expect(!unknown.success)

        let invalidRequests: [(TCPViewerMCPCommand, [String: TCPViewerMCPValue]?)] = [
            (.getPacketDetails, nil),
            (.getPacketDetails, ["packet_id": .string("999")]),
            (.getPacketDetails, ["packet_id": .string("1"), "max_depth": .int(99)]),
            (.getPacketBytes, ["packet_id": .string("1"), "encoding": .string("binary")]),
            (.getPacketBytes, ["packet_id": .string("1"), "length": .int(0)]),
            (.listStreamPackets, nil),
            (.revealPacket, ["packet_id": .string("999")]),
            (.startCapture, ["interface_id": .int(1)]),
            (.startCapture, ["capture_filter": .string(String(repeating: "x", count: 4_097))]),
            (.exportPackets, ["path": .string("relative.pcap"), "all": .bool(true)]),
            (.exportPackets, ["path": .string("/tmp/file.pcap"), "format": .string("txt"), "all": .bool(true)]),
            (.exportPackets, ["path": .string("/tmp/file.pcap")]),
        ]
        for (command, params) in invalidRequests {
            #expect(!(await routeMCP(router, command: command, params: params)).success, "Expected \(command.rawValue) to fail")
        }
    }

    @Test func propagatesControlExportAndClearFailures() async throws {
        let source = TCPViewerMCPFakeDataSource()
        let error = NSError(domain: "TCPViewerMCPTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation failed token=private"])
        source.controlError = error
        source.exportError = error
        source.clearError = error
        let router = makeRouter(source: source, redactsSensitiveData: { true })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerMCPFailures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = await routeMCP(router, command: .startCapture)
        let export = await routeMCP(router, command: .exportPackets, params: [
            "path": .string(directory.appendingPathComponent("all.pcap").path),
            "format": .string("pcap"),
            "all": .bool(true),
        ])
        let clear = await routeMCP(router, command: .clearPackets, params: ["confirm": .bool(true)])

        #expect(!start.success && !export.success && !clear.success)
        #expect(start.error?.contains("private") == false)
        #expect(start.error?.contains(TCPViewerMCPSensitiveDataRedactor.placeholder) == true)
    }

    @Test func exportPathPolicyRejectsUnsafeReplacementAndWrongTypes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerMCPPath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = TCPViewerMCPExportPathPolicy()

        let existing = directory.appendingPathComponent("existing.pcap")
        try Data("fixture".utf8).write(to: existing)
        #expect(throws: Error.self) {
            try policy.destination(path: existing.path, format: .pcap, overwrite: false)
        }
        #expect(try policy.destination(path: existing.path, format: .pcap, overwrite: true) == existing.standardizedFileURL)
        #expect(throws: Error.self) {
            try policy.destination(path: existing.path, format: .pcapng, overwrite: true)
        }
        let directoryDestination = directory.appendingPathComponent("folder.pcap")
        try FileManager.default.createDirectory(at: directoryDestination, withIntermediateDirectories: false)
        #expect(throws: Error.self) {
            try policy.destination(path: directoryDestination.path, format: .pcap, overwrite: true)
        }

        let link = directory.appendingPathComponent("link.pcap")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        #expect(throws: Error.self) {
            try policy.destination(path: link.path, format: .pcap, overwrite: true)
        }

        let fifo = directory.appendingPathComponent("pipe.pcap")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: Error.self) {
            try policy.destination(path: fifo.path, format: .pcap, overwrite: true)
        }
    }

    private func makeRouter(
        source: TCPViewerMCPFakeDataSource,
        redactsSensitiveData: @escaping () -> Bool
    ) -> TCPViewerMCPCommandRouter {
        TCPViewerMCPCommandRouter(
            dataSourceProvider: { source },
            isLicenseAuthorized: { true },
            redactionEnabled: redactsSensitiveData,
            versionProvider: {
                TCPViewerLicenseAppVersion(
                    bundleInfo: ["CFBundleShortVersionString": "1.9.0", "CFBundleVersion": "30"],
                    osVersion: "macOS"
                )
            }
        )
    }

    private func routeRaw(_ router: TCPViewerMCPCommandRouter, command: String) async -> TCPViewerMCPResponse {
        await withCheckedContinuation { continuation in
            router.route(TCPViewerMCPRequest(command: command)) { continuation.resume(returning: $0) }
        }
    }
}
