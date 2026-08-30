//
//  TCPViewerCLICommandCoordinator.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation

final class TCPViewerCLICommandCoordinator {
    private let fileStore: TCPViewerCLIFileStore
    private let notificationCenter: any TCPViewerCLINotificationCentering
    private let router: any TCPViewerCLICommandRouting
    private let workerQueue = DispatchQueue(label: "com.proxyman.tcpviewer.cli.requests", qos: .userInitiated)
    private var requestObserver: (any TCPViewerCLINotificationObserving)?
    private var isProcessing = false

    init(
        appDelegate: AppDelegate,
        fileStore: TCPViewerCLIFileStore = TCPViewerCLIFileStore(),
        notificationCenter: any TCPViewerCLINotificationCentering = TCPViewerCLIDarwinNotificationCenter.shared
    ) {
        self.fileStore = fileStore
        self.notificationCenter = notificationCenter
        self.router = TCPViewerCLICommandRouter(appDelegate: appDelegate)
    }

    init(
        fileStore: TCPViewerCLIFileStore,
        notificationCenter: any TCPViewerCLINotificationCentering,
        router: any TCPViewerCLICommandRouting
    ) {
        self.fileStore = fileStore
        self.notificationCenter = notificationCenter
        self.router = router
    }

    // Register before scanning so startup cannot lose a request arriving between those operations.
    func start() {
        guard requestObserver == nil else { return }
        requestObserver = notificationCenter.observe(TCPViewerCLINotificationName.request) { [weak self] in
            self?.scheduleDrain()
        }
        scheduleDrain()
    }

    func stop() {
        requestObserver = nil
    }

    private func scheduleDrain() {
        workerQueue.async { [weak self] in
            self?.drainNextRequest()
        }
    }

    private func drainNextRequest() {
        guard !isProcessing else { return }
        try? fileStore.prepareDirectories()
        fileStore.cleanupOrphans()
        guard let request = fileStore.pendingRequests().first else { return }
        isProcessing = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.router.route(request) { response in
                self.workerQueue.async {
                    try? self.fileStore.writeResponse(response)
                    self.fileStore.removeRequest(requestID: request.requestID)
                    self.notificationCenter.post(TCPViewerCLINotificationName.response)
                    self.isProcessing = false
                    self.drainNextRequest()
                }
            }
        }
    }
}
