//
//  Document.swift
//  Packetman
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
        let services = PacketryServiceRegistry(
            core: NativePacketryCore(),
            networkHelperTool: appDelegate?.networkHelperToolManager ?? PacketryNetworkHelperToolManager()
        )
        let windowController = PacketmanWindowController(
            services: services,
            initialURL: openedCaptureURL ?? fileURL
        )
        addWindowController(windowController)
    }

    override func data(ofType typeName: String) throws -> Data {
        Data()
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
    }

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        openedCaptureURL = url
    }
}
