//
//  TCPViewerCaptureWorkspace.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import Foundation
import PcapPlusPlusCore

/// Owns one capture dataset independently of the panes that display it.
final class TCPViewerCaptureWorkspace: TCPViewerWorkspaceControllerDelegate {
    enum Kind { case live, offline }

    private final class Subscription {
        weak var delegate: (any TCPViewerWorkspaceControllerDelegate)?
        init(_ delegate: any TCPViewerWorkspaceControllerDelegate) { self.delegate = delegate }
    }

    let kind: Kind
    let controller: TCPViewerWorkspaceController
    let sourceListService = PacketSourceListService()
    let pinService: PacketPinService
    let savedPacketService: SavedPacketService
    let customFilterService: PacketCustomFilterService
    let statusMetricsService: TCPViewerStatusMetricsService
    private var subscriptions: [Subscription] = []
    private(set) var isClosed = false
    private var isClosing = false
    private var closeCompletions: [(Bool) -> Void] = []

    init(
        services: TCPViewerServiceRegistry,
        kind: Kind = .live,
        userDefaults: UserDefaults = .standard,
        interfaceHistoryStore: InterfaceSelectionHistoryStore? = nil,
        pinService: PacketPinService = PacketPinService(),
        savedPacketService: SavedPacketService = SavedPacketService(),
        customFilterService: PacketCustomFilterService = PacketCustomFilterService(),
        statusMetricsService: TCPViewerStatusMetricsService = TCPViewerStatusMetricsService()
    ) {
        self.kind = kind
        self.controller = TCPViewerWorkspaceController(services: services, userDefaults: userDefaults,
                                                     interfaceHistoryStore: interfaceHistoryStore)
        self.pinService = pinService
        self.savedPacketService = savedPacketService
        self.customFilterService = customFilterService
        self.statusMetricsService = statusMetricsService
        controller.delegate = self
        if kind == .offline {
            pinService.useDocumentPins(pinService.pins())
            savedPacketService.useDocumentRecords([])
            customFilterService.useDocumentFilters(customFilterService.filters())
        }
        statusMetricsService.snapshotHandler = { [weak self] _ in self?.publishChange() }
        if kind == .live { statusMetricsService.start() }
    }

    // Weak subscriptions never extend a closed pane's lifetime.
    func subscribe(_ delegate: any TCPViewerWorkspaceControllerDelegate) {
        subscriptions.removeAll { $0.delegate == nil || $0.delegate === delegate }
        subscriptions.append(Subscription(delegate))
    }

    func unsubscribe(_ delegate: any TCPViewerWorkspaceControllerDelegate) {
        subscriptions.removeAll { $0.delegate == nil || $0.delegate === delegate }
    }

    func publishChange() {
        guard !isClosed else { return }
        subscriptions.removeAll { $0.delegate == nil }
        for subscription in subscriptions { subscription.delegate?.tcpViewerWorkspaceControllerDidChange(controller) }
    }

    // Ingest and metrics run once per source, even when no live pane is selected.
    func tcpViewerWorkspaceControllerDidChange(_ controller: TCPViewerWorkspaceController) {
        // With no pane consuming deltas, rebuild the sidebar once when a pane returns.
        if subscriptions.allSatisfy({ $0.delegate == nil }) {
            sourceListService.reset()
        }
        let base = controller.snapshot
        let interface = base.sessionState.phase == .running && base.packetIngestState.source == .live
            ? base.sessionState.selectedInterface : nil
        let addresses = Set((interface?.addresses ?? []).compactMap { address -> String? in
            switch address.family {
            case .ipv4, .ipv6: return address.value
            default: return nil
            }
        })
        _ = statusMetricsService.updateMonitoring(interfaceID: interface?.id, localAddresses: addresses,
                                                 baselineIngestState: base.packetIngestState, startsTimer: kind == .live)
        statusMetricsService.recordPacketIngestState(base.packetIngestState)
        publishChange()
    }

    // Release offline resources explicitly; live shutdown uses the existing stop acknowledgement.
    func close(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isClosed else { completion(true); return }
        closeCompletions.append(completion)
        guard !isClosing else { return }
        isClosing = true
        if kind == .offline {
            controller.cancelDocumentLoading()
            controller.cancelSessionImport()
        }
        controller.prepareForApplicationTermination { [weak self] succeeded in
            if succeeded, let self {
                self.isClosed = true
                self.subscriptions.removeAll()
                self.controller.delegate = nil
                self.sourceListService.reset()
                self.statusMetricsService.snapshotHandler = nil
                self.statusMetricsService.stop()
                self.controller.releaseWorkspaceStorage()
            }
            guard let self else { completion(succeeded); return }
            self.isClosing = false
            let callbacks = self.closeCompletions
            self.closeCompletions.removeAll()
            callbacks.forEach { $0(succeeded) }
        }
    }

    deinit { statusMetricsService.stop() }

    #if DEBUG
    var subscriberCountForTesting: Int { subscriptions.filter { $0.delegate != nil }.count }
    #endif
}
