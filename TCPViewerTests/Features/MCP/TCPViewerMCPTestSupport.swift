//
//  TCPViewerMCPTestSupport.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import PcapPlusPlusCore
@testable import TCPViewer

func makeMCPPacket(
    id: UInt64,
    protocolName: String = "TLS",
    domain: String? = "api.example.com",
    sourceAddress: String = "10.0.0.1",
    destinationAddress: String = "93.184.216.34",
    sourcePort: UInt16 = 51_234,
    destinationPort: UInt16 = 443,
    streamID: UInt32? = 7,
    info: String = "Authorization: Bearer secret-value",
    capturedLength: Int = 128,
    isTruncated: Bool = false
) -> PacketSummary {
    PacketSummary(
        id: id,
        packetNumber: id + 100,
        timestamp: Date(timeIntervalSince1970: 1_720_000_000 + Double(id)),
        source: .live,
        interfaceID: "en0",
        transportHint: protocolName == "DNS" ? .dns : .tls,
        protocolSummary: protocolName,
        endpoints: PacketEndpoints(
            source: PacketEndpoint(address: sourceAddress, port: sourcePort),
            destination: PacketEndpoint(address: destinationAddress, port: destinationPort)
        ),
        originalLength: capturedLength + (isTruncated ? 20 : 0),
        capturedLength: capturedLength,
        streamID: streamID,
        direction: .outbound,
        tcpFlags: "SYN, ACK",
        tcpPayloadLength: 64,
        infoSummary: info,
        layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: protocolName)],
        decodeStatus: PacketDecodeStatus(kind: isTruncated ? .partial : .complete, reason: isTruncated ? "Frame truncated" : nil),
        captureMetadata: PacketCaptureMetadata(
            linkType: .ethernet,
            isTruncated: isTruncated,
            packetComment: "token=comment-secret",
            interfaceName: "Wi-Fi"
        ),
        sniDomainName: domain,
        client: PacketClient(
            pid: 42,
            name: "ExampleClient",
            displayName: "Example Client",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            bundleIdentifier: "com.example.client",
            bundlePath: "/Applications/Example.app"
        )
    )
}

func makeMCPInspection(packetID: UInt64 = 1) -> PacketInspection {
    PacketInspection(
        packetID: packetID,
        packetNumber: packetID + 100,
        rawBytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
        byteViews: [PacketByteView(id: "frame", label: "Frame", bytes: Data([0x01, 0x02]))],
        detailNodes: [
            PacketDetailNode(
                id: "http.authorization",
                name: "Authorization",
                fieldName: "authorization",
                value: "Bearer super-secret-token",
                rawValue: "Authorization: Bearer super-secret-token",
                kind: .field,
                byteRange: PacketByteRange(offset: 0, length: 2),
                children: [
                    PacketDetailNode(
                        id: "http.url",
                        name: "Request URL",
                        fieldName: "url",
                        value: "https://example.com/path?api_key=hidden&safe=yes"
                    ),
                ]
            ),
        ],
        decodeStatus: PacketDecodeStatus(kind: .complete)
    )
}

func makeMCPInterface() -> CaptureInterfaceSummary {
    CaptureInterfaceSummary(
        id: "en0",
        technicalName: "en0",
        displayName: "Wi-Fi",
        friendlyName: "Office Wi-Fi",
        isLoopback: false,
        addresses: [CaptureInterfaceAddress(family: .ipv4, value: "10.0.0.1")],
        linkType: .ethernet,
        availability: .available,
        activityPreview: CaptureInterfaceActivityPreview(packetsPerSecond: 12.5),
        capabilities: CaptureInterfaceCapabilities(
            canCapture: true,
            supportsPromiscuousMode: true,
            requiresBPFPermissionSetup: false,
            providesMacOSMetadata: true
        )
    )
}

final class TCPViewerMCPFakeDataSource: TCPViewerMCPDataSource {
    var packets: [PacketSummary]
    var inspections: [UInt64: PacketInspection]
    var interfaces = [makeMCPInterface()]
    var capturePhase = "ready"
    var selectedInterfaceID: String? = "en0"
    var activeInterfaceID: String?
    var captureFilter = ""
    var statusMessage = "Ready"
    var controlError: Error?
    var clearError: Error?
    var exportError: Error?
    var exportedIDs: [UInt64] = []
    var exportedURL: URL?
    var exportedFormat: CaptureFileFormat?
    var startedInterfaceID: String?
    var startedCaptureFilter: String?
    var paused = false
    var resumed = false
    var stopped = false
    var cleared = false
    var revealedPacketID: UInt64?

    init(packets: [PacketSummary] = [makeMCPPacket(id: 1), makeMCPPacket(id: 2, protocolName: "DNS", domain: "dns.example")]) {
        self.packets = packets
        self.inspections = Dictionary(uniqueKeysWithValues: packets.map { ($0.id, makeMCPInspection(packetID: $0.id)) })
    }

    func mcpWorkspaceSnapshot(
        packetLimit: Int,
        packetOffset: Int,
        packetOrder: TCPViewerMCPPacketOrder
    ) -> TCPViewerMCPWorkspaceSnapshot {
        let selectedPackets = TCPViewerMCPPacketWindow.packets(
            from: packets,
            offset: packetOffset,
            limit: packetLimit,
            order: packetOrder
        )
        return TCPViewerMCPWorkspaceSnapshot(
            packets: selectedPackets,
            totalPacketCount: packets.count,
            interfaces: interfaces,
            capturePhase: capturePhase,
            selectedInterfaceID: selectedInterfaceID,
            activeInterfaceID: activeInterfaceID,
            captureFilter: captureFilter,
            statusMessage: statusMessage,
            source: .live,
            documentURL: nil,
            canStart: true,
            canPause: true,
            canResume: true,
            canStop: true,
            droppedPacketCount: 3,
            truncatedPacketCount: packets.filter(\.captureMetadata.isTruncated).count,
            decodeIssueCount: packets.filter { $0.decodeStatus.kind != .complete }.count
        )
    }

    func mcpInspectPacket(id: UInt64, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        if let inspection = inspections[id] {
            completion(.success(inspection))
        } else {
            completion(.failure(TCPViewerMCPDataSourceError.packetNotFound(id)))
        }
    }

    func mcpExportPackets(
        ids: [UInt64],
        to url: URL,
        format: CaptureFileFormat,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        exportedIDs = ids
        exportedURL = url
        exportedFormat = format
        if let exportError {
            completion(.failure(exportError))
        } else {
            completion(.success(()))
        }
    }

    func mcpStartCapture(
        interfaceID: String?,
        captureFilter: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        startedInterfaceID = interfaceID
        startedCaptureFilter = captureFilter
        completeControl(completion)
    }

    func mcpPauseCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        paused = true
        completeControl(completion)
    }

    func mcpResumeCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        resumed = true
        completeControl(completion)
    }

    func mcpStopCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        stopped = true
        completeControl(completion)
    }

    func mcpClearPackets() -> Result<Int, Error> {
        if let clearError {
            return .failure(clearError)
        }
        let count = packets.count
        cleared = true
        packets = []
        return .success(count)
    }

    func mcpRevealPacket(id: UInt64) -> Result<Void, Error> {
        guard packets.contains(where: { $0.id == id }) else {
            return .failure(TCPViewerMCPDataSourceError.packetNotFound(id))
        }
        revealedPacketID = id
        return .success(())
    }

    private func completeControl(_ completion: @escaping (Result<Void, Error>) -> Void) {
        if let controlError {
            completion(.failure(controlError))
        } else {
            completion(.success(()))
        }
    }
}

func routeMCP(
    _ router: TCPViewerMCPCommandRouter,
    command: TCPViewerMCPCommand,
    params: [String: TCPViewerMCPValue]? = nil
) async -> TCPViewerMCPResponse {
    await withCheckedContinuation { continuation in
        router.route(TCPViewerMCPRequest(command: command.rawValue, params: params)) { response in
            continuation.resume(returning: response)
        }
    }
}

extension TCPViewerMCPResponse {
    func value(_ key: String) -> TCPViewerMCPValue? {
        data?[key]
    }
}
