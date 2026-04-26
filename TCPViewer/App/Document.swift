//
//  Document.swift
//  TCPViewer
//
//  Created by nghiatran on 24/4/26.
//

import Cocoa
import PcapPlusPlusCore

class Document: NSDocument {
    nonisolated(unsafe) private var openedCaptureURL: URL?

    override init() {
        super.init()
    }

    override nonisolated class var autosavesInPlace: Bool {
        false
    }

    override func makeWindowControllers() {
        let appDelegate = NSApp.delegate as? AppDelegate
        let services = TCPViewerServiceRegistry(
            core: NativeTCPViewerCore(),
            networkHelperTool: appDelegate?.networkHelperToolManager ?? TCPViewerNetworkHelperToolManager()
        )
        let windowController = TCPViewerWindowController(
            services: services,
            configuration: appDelegate?.appConfiguration ?? AppConfiguration(),
            initialURL: openedCaptureURL ?? fileURL
        )
        addWindowController(windowController)
    }

    @IBAction func exportSessionAsPcap(_ sender: Any?) {
        tcpviewerWindowController?.rootViewController.exportSession(format: .pcap)
    }

    @IBAction func exportSessionAsPcapng(_ sender: Any?) {
        tcpviewerWindowController?.rootViewController.exportSession(format: .pcapng)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(exportSessionAsPcap(_:)), #selector(exportSessionAsPcapng(_:)):
            return canExportSession
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        Data()
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
    }

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        openedCaptureURL = url
    }

    private var tcpviewerWindowController: TCPViewerWindowController? {
        windowControllers.compactMap { $0 as? TCPViewerWindowController }.first
    }

    private var canExportSession: Bool {
        guard let snapshot = tcpviewerWindowController?.rootViewController.viewModel.snapshot else {
            return false
        }

        return snapshot.totalPacketCount > 0 && snapshot.base.loadState.progress.phase != .loading
    }
}
