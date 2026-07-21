//
//  TCPViewerMCPDataSource.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import AppKit
import Foundation
import PcapPlusPlusCore

struct TCPViewerMCPWorkspaceSnapshot: Sendable {
    let packets: [PacketSummary]
    let totalPacketCount: Int
    let interfaces: [CaptureInterfaceSummary]
    let capturePhase: String
    let selectedInterfaceID: String?
    let activeInterfaceID: String?
    let captureFilter: String
    let statusMessage: String
    let source: CaptureSource?
    let documentURL: URL?
    let canStart: Bool
    let canPause: Bool
    let canResume: Bool
    let canStop: Bool
    let droppedPacketCount: UInt64
    let truncatedPacketCount: Int
    let decodeIssueCount: Int
}

protocol TCPViewerMCPDataSource: AnyObject {
    func mcpWorkspaceSnapshot(
        packetLimit: Int,
        packetOffset: Int,
        packetOrder: TCPViewerMCPPacketOrder
    ) -> TCPViewerMCPWorkspaceSnapshot
    func mcpInspectPacket(
        id: PacketSummary.ID,
        completion: @escaping TCPViewerCompletion<PacketInspection>
    )
    func mcpExportPackets(
        ids: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        completion: @escaping TCPViewerVoidCompletion
    )
    func mcpStartCapture(
        interfaceID: String?,
        captureFilter: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func mcpPauseCapture(completion: @escaping (Result<Void, Error>) -> Void)
    func mcpResumeCapture(completion: @escaping (Result<Void, Error>) -> Void)
    func mcpStopCapture(completion: @escaping (Result<Void, Error>) -> Void)
    func mcpClearPackets() -> Result<Int, Error>
    func mcpRevealPacket(id: PacketSummary.ID) -> Result<Void, Error>
}

extension TCPViewerMCPDataSource {
    func mcpWorkspaceSnapshot() -> TCPViewerMCPWorkspaceSnapshot {
        mcpWorkspaceSnapshot(packetLimit: 0, packetOffset: 0, packetOrder: .recent)
    }
}

enum TCPViewerMCPPacketWindow {
    // Copy one bounded prefix or suffix window after skipping packets in the requested order.
    static func packets(
        from packets: [PacketSummary],
        offset: Int,
        limit: Int,
        order: TCPViewerMCPPacketOrder
    ) -> [PacketSummary] {
        let skippedCount = min(max(offset, 0), packets.count)
        let boundedLimit = max(limit, 0)
        switch order {
        case .recent:
            let endIndex = packets.count - skippedCount
            let count = min(boundedLimit, endIndex)
            return Array(packets[(endIndex - count)..<endIndex])
        case .oldest:
            let startIndex = skippedCount
            let count = min(boundedLimit, packets.count - startIndex)
            return Array(packets[startIndex..<(startIndex + count)])
        }
    }
}

enum TCPViewerMCPDataSourceError: Error, LocalizedError {
    case invalidState(String)
    case packetNotFound(PacketSummary.ID)

    var errorDescription: String? {
        switch self {
        case .invalidState(let message):
            return message
        case .packetNotFound(let id):
            return "Packet \(id) is not available in the active TCP Viewer window."
        }
    }
}

extension NetworkInspectorViewModel: TCPViewerMCPDataSource {
    // Copy only the requested packet window so live appends never clone the full capture.
    func mcpWorkspaceSnapshot(
        packetLimit: Int,
        packetOffset: Int,
        packetOrder: TCPViewerMCPPacketOrder
    ) -> TCPViewerMCPWorkspaceSnapshot {
        let base = snapshot.base
        let boundedLimit = max(0, min(packetLimit, TCPViewerMCPPacketQuery.maximumScanLimit))
        let packets = TCPViewerMCPPacketWindow.packets(
            from: base.packetIngestState.packets,
            offset: packetOffset,
            limit: boundedLimit,
            order: packetOrder
        )
        return TCPViewerMCPWorkspaceSnapshot(
            packets: packets,
            totalPacketCount: base.packetIngestState.packets.count,
            interfaces: base.sessionState.interfaceInventory,
            capturePhase: base.sessionState.phase.rawValue,
            selectedInterfaceID: base.sessionState.selectedInterfaceID,
            activeInterfaceID: base.sessionState.activeInterfaceID,
            captureFilter: base.filterState.captureFilterText,
            statusMessage: base.sessionState.statusMessage,
            source: base.packetIngestState.source,
            documentURL: base.documentState.fileURL,
            canStart: base.sessionState.canStart,
            canPause: base.sessionState.canPause,
            canResume: base.sessionState.canResume,
            canStop: base.sessionState.canStop,
            droppedPacketCount: base.sessionState.health.packetsDropped + base.sessionState.health.packetsDroppedByInterface,
            truncatedPacketCount: base.packetIngestState.truncatedPacketCount,
            decodeIssueCount: base.packetIngestState.decodeIssueCount
        )
    }

    func mcpInspectPacket(
        id: PacketSummary.ID,
        completion: @escaping TCPViewerCompletion<PacketInspection>
    ) {
        guard snapshot.base.packetIngestState.packet(withID: id) != nil else {
            completion(.failure(TCPViewerMCPDataSourceError.packetNotFound(id)))
            return
        }
        inspectPacket(id, completion: completion)
    }

    func mcpExportPackets(
        ids: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        exportPackets(ids, to: url, format: format, completion: completion)
    }

    func mcpStartCapture(
        interfaceID: String?,
        captureFilter: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if let interfaceID {
            guard snapshot.base.sessionState.interfaceInventory.contains(where: {
                $0.id == interfaceID && $0.isSelectable
            }) else {
                completion(.failure(TCPViewerMCPDataSourceError.invalidState(
                    "The requested capture interface is unavailable."
                )))
                return
            }
            selectInterface(interfaceID)
        }
        if let captureFilter {
            updateCaptureFilterText(captureFilter)
        }

        guard snapshot.base.sessionState.canStart else {
            completion(.failure(TCPViewerMCPDataSourceError.invalidState(
                snapshot.base.sessionState.statusMessage
            )))
            return
        }

        toggleLiveCapture { [weak self] in
            guard let self else {
                completion(.failure(TCPViewerMCPDataSourceError.invalidState("TCP Viewer window closed while capture was starting.")))
                return
            }
            self.finishMCPControl(
                expectedPhase: .running,
                transitionalPhases: [.starting],
                deadline: .now() + 5,
                completion: completion
            )
        }
    }

    func mcpPauseCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        guard snapshot.base.sessionState.canPause else {
            completion(.failure(TCPViewerMCPDataSourceError.invalidState("The active capture cannot be paused right now.")))
            return
        }
        pauseLiveCapture { [weak self] in
            guard let self else {
                completion(.failure(TCPViewerMCPDataSourceError.invalidState("TCP Viewer window closed while capture was pausing.")))
                return
            }
            self.finishMCPControl(
                expectedPhase: .paused,
                transitionalPhases: [.running],
                deadline: .now() + 5,
                completion: completion
            )
        }
    }

    func mcpResumeCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        guard snapshot.base.sessionState.canResume else {
            completion(.failure(TCPViewerMCPDataSourceError.invalidState("The active capture cannot be resumed right now.")))
            return
        }
        resumeLiveCapture { [weak self] in
            guard let self else {
                completion(.failure(TCPViewerMCPDataSourceError.invalidState("TCP Viewer window closed while capture was resuming.")))
                return
            }
            self.finishMCPControl(
                expectedPhase: .running,
                transitionalPhases: [.paused],
                deadline: .now() + 5,
                completion: completion
            )
        }
    }

    func mcpStopCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        guard snapshot.base.sessionState.canStop else {
            completion(.failure(TCPViewerMCPDataSourceError.invalidState("There is no active capture to stop.")))
            return
        }
        stopLiveCapture { [weak self] in
            guard let self else {
                completion(.failure(TCPViewerMCPDataSourceError.invalidState("TCP Viewer window closed while capture was stopping.")))
                return
            }
            self.finishMCPControl(
                expectedPhase: .stopped,
                transitionalPhases: [.running, .paused, .stopping],
                deadline: .now() + 5,
                completion: completion
            )
        }
    }

    func mcpClearPackets() -> Result<Int, Error> {
        guard !snapshot.base.loadState.canCancel else {
            return .failure(TCPViewerMCPDataSourceError.invalidState("Wait for the current capture file operation to finish before clearing packets."))
        }
        let count = snapshot.totalPacketCount
        clearPackets()
        return .success(count)
    }

    func mcpRevealPacket(id: PacketSummary.ID) -> Result<Void, Error> {
        guard snapshot.base.packetIngestState.packet(withID: id) != nil else {
            return .failure(TCPViewerMCPDataSourceError.packetNotFound(id))
        }
        selectPacket(id)
        setInspectorVisible(true)
        return .success(())
    }

    // Wait for the controller's deferred phase event to reach the view-model snapshot.
    private func finishMCPControl(
        expectedPhase: CaptureSessionState.Phase,
        transitionalPhases: Set<CaptureSessionState.Phase>,
        deadline: DispatchTime,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if let error = snapshot.base.sessionState.lastError {
            completion(.failure(error))
        } else if snapshot.base.sessionState.phase == expectedPhase {
            completion(.success(()))
        } else if transitionalPhases.contains(snapshot.base.sessionState.phase),
                  DispatchTime.now() < deadline {
            // Controller completions precede phase events, so wait for the coalesced view-model snapshot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else {
                    completion(.failure(TCPViewerMCPDataSourceError.invalidState(
                        "TCP Viewer window closed before the capture state was updated."
                    )))
                    return
                }
                self.finishMCPControl(
                    expectedPhase: expectedPhase,
                    transitionalPhases: transitionalPhases,
                    deadline: deadline,
                    completion: completion
                )
            }
        } else {
            completion(.failure(TCPViewerMCPDataSourceError.invalidState(
                snapshot.base.sessionState.statusMessage
            )))
        }
    }
}

final class TCPViewerMCPServiceProvider {
    static let shared = TCPViewerMCPServiceProvider()

    private final class Entry {
        weak var source: (any TCPViewerMCPDataSource)?
        weak var window: NSWindow?

        init(source: any TCPViewerMCPDataSource, window: NSWindow?) {
            self.source = source
            self.window = window
        }
    }

    private var entries: [Entry] = []

    private init() {}

    // Register each document window without creating global ownership of its controller state.
    func register(source: any TCPViewerMCPDataSource, window: NSWindow?) {
        precondition(Thread.isMainThread)
        pruneReleasedEntries()
        guard !entries.contains(where: { $0.source === source }) else {
            return
        }
        entries.append(Entry(source: source, window: window))
    }

    func activeSource() -> (any TCPViewerMCPDataSource)? {
        precondition(Thread.isMainThread)
        pruneReleasedEntries()

        if let keyWindow = NSApp.keyWindow,
           let source = entries.first(where: { $0.window === keyWindow })?.source {
            return source
        }
        if let mainWindow = NSApp.mainWindow,
           let source = entries.first(where: { $0.window === mainWindow })?.source {
            return source
        }
        return entries.reversed().compactMap(\.source).first
    }

    private func pruneReleasedEntries() {
        entries.removeAll { $0.source == nil }
    }
}
