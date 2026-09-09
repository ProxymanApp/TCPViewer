//
//  TCPViewerWorkspaceAutomationSource.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import AppKit
import PcapPlusPlusCore

/// Capture commands use the live source; packet commands bind to the selected pane at dispatch.
final class TCPViewerWorkspaceAutomationSource: TCPViewerMCPDataSource {
    private weak var windowController: TCPViewerWindowController?
    private weak var commandPane: NetworkInspectorViewModel?
    private var isBoundToCommand = false
    private var pane: NetworkInspectorViewModel? {
        isBoundToCommand ? commandPane : windowController?.selectedTab?.pane?.viewModel
    }
    private var live: TCPViewerWorkspaceController? { windowController?.liveWorkspace.controller }
    private static let unavailable = TCPViewerMCPDataSourceError.invalidState("The workspace is closed.")

    init(windowController: TCPViewerWindowController) { self.windowController = windowController }

    // Bind once before any asynchronous command stage; switching tabs cannot retarget the request.
    func sourceForCommand() -> any TCPViewerMCPDataSource {
        guard let windowController else { return self }
        let source = TCPViewerWorkspaceAutomationSource(windowController: windowController)
        source.commandPane = pane
        source.isBoundToCommand = true
        return source
    }

    func mcpWorkspaceSnapshot(packetLimit: Int, packetOffset: Int, packetOrder: TCPViewerMCPPacketOrder) -> TCPViewerMCPWorkspaceSnapshot {
        let active = pane?.mcpWorkspaceSnapshot(packetLimit: packetLimit, packetOffset: packetOffset, packetOrder: packetOrder)
        let source = live?.snapshot ?? .foundation
        return TCPViewerMCPWorkspaceSnapshot(
            packets: active?.packets ?? [], totalPacketCount: active?.totalPacketCount ?? 0,
            interfaces: source.sessionState.interfaceInventory, capturePhase: source.sessionState.phase.rawValue,
            selectedInterfaceID: source.sessionState.selectedInterfaceID, activeInterfaceID: source.sessionState.activeInterfaceID,
            captureFilter: source.filterState.captureFilterText, statusMessage: source.sessionState.statusMessage,
            source: active?.source, documentURL: active?.documentURL,
            canStart: source.sessionState.canStart, canPause: source.sessionState.canPause,
            canResume: source.sessionState.canResume, canStop: source.sessionState.canStop,
            droppedPacketCount: source.sessionState.health.packetsDropped + source.sessionState.health.packetsDroppedByInterface,
            truncatedPacketCount: active?.truncatedPacketCount ?? 0, decodeIssueCount: active?.decodeIssueCount ?? 0
        )
    }

    func mcpInspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        guard let pane else { completion(.failure(Self.unavailable)); return }
        pane.mcpInspectPacket(id: id, completion: completion)
    }

    func mcpExportPackets(ids: [PacketSummary.ID], to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        guard let pane else { completion(.failure(Self.unavailable)); return }
        pane.mcpExportPackets(ids: ids, to: url, format: format, completion: completion)
    }

    func mcpClearPackets() -> Result<Int, Error> { pane?.mcpClearPackets() ?? .failure(Self.unavailable) }
    func mcpRevealPacket(id: PacketSummary.ID) -> Result<Void, Error> { pane?.mcpRevealPacket(id: id) ?? .failure(Self.unavailable) }

    func mcpStartCapture(interfaceID: String?, captureFilter: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let live else { completion(.failure(Self.unavailable)); return }
        live.performInitialLoadIfNeeded {
            if let interfaceID { live.selectInterface(interfaceID) }
            if let captureFilter { live.updateCaptureFilterText(captureFilter) }
            guard live.snapshot.sessionState.canStart else {
                completion(.failure(TCPViewerMCPDataSourceError.invalidState(live.snapshot.sessionState.statusMessage))); return
            }
            live.startLiveCapture { Self.finish(live, expected: .running, completion: completion) }
        }
    }

    func mcpPauseCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let live, live.snapshot.sessionState.canPause else { completion(.failure(Self.unavailable)); return }
        live.pauseLiveCapture { Self.finish(live, expected: .paused, completion: completion) }
    }

    func mcpResumeCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let live, live.snapshot.sessionState.canResume else { completion(.failure(Self.unavailable)); return }
        live.resumeLiveCapture { Self.finish(live, expected: .running, completion: completion) }
    }

    func mcpStopCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let live, live.snapshot.sessionState.canStop else { completion(.failure(Self.unavailable)); return }
        live.stopLiveCapture { Self.finish(live, expected: .stopped, completion: completion) }
    }

    // Native phase events can arrive after the control callback; poll only this bounded operation.
    private static func finish(_ controller: TCPViewerWorkspaceController, expected: CaptureSessionState.Phase,
                               remaining: Int = 100, completion: @escaping (Result<Void, Error>) -> Void) {
        let state = controller.snapshot.sessionState
        if state.phase == expected { completion(.success(())); return }
        if let error = state.lastError { completion(.failure(error)); return }
        guard remaining > 0 else {
            completion(.failure(TCPViewerMCPDataSourceError.invalidState(state.statusMessage))); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            finish(controller, expected: expected, remaining: remaining - 1, completion: completion)
        }
    }
}
