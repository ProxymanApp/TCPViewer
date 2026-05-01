//
//  CallbackTestSupport.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Foundation
import PcapPlusPlusCore
@testable import TCPViewer

extension TCPViewerWorkspaceController {
    func performInitialLoadIfNeeded() async {
        await waitForCompletion { performInitialLoadIfNeeded(completion: $0) }
    }

    func refreshInterfaces() async {
        await waitForCompletion { refreshInterfaces(completion: $0) }
    }

    func startLiveCapture() async {
        await waitForCompletion { startLiveCapture(completion: $0) }
    }

    func pauseLiveCapture() async {
        await waitForCompletion { pauseLiveCapture(completion: $0) }
    }

    func resumeLiveCapture() async {
        await waitForCompletion { resumeLiveCapture(completion: $0) }
    }

    func stopLiveCapture() async {
        await waitForCompletion { stopLiveCapture(completion: $0) }
    }

    func openDocument(at fileURL: URL) async {
        await waitForCompletion { openDocument(at: fileURL, completion: $0) }
    }

    func reopenDocument() async {
        await waitForCompletion { reopenDocument(completion: $0) }
    }

    func saveDocument() async {
        await waitForCompletion { saveDocument(completion: $0) }
    }

    func saveDocument(to url: URL, format: CaptureFileFormat) async {
        await waitForCompletion { saveDocument(to: url, format: format, completion: $0) }
    }

    func exportPackets(withIDs identifiers: [PacketSummary.ID], to url: URL, format: CaptureFileFormat) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            exportPackets(withIDs: identifiers, to: url, format: format) { result in
                continuation.resume(returning: result)
            }
        }
    }

    func prepareForApplicationTermination() async -> Bool {
        await withCheckedContinuation { continuation in
            prepareForApplicationTermination { shouldTerminate in
                continuation.resume(returning: shouldTerminate)
            }
        }
    }
}

extension NetworkInspectorViewModel {
    func performInitialLoadIfNeeded() async {
        await waitForCompletion { performInitialLoadIfNeeded(completion: $0) }
    }

    func toggleLiveCapture() async {
        await waitForCompletion { toggleLiveCapture(completion: $0) }
    }

    func openDocument(at fileURL: URL) async {
        await waitForCompletion { openDocument(at: fileURL, completion: $0) }
    }

    func saveDocument() async {
        await waitForCompletion { saveDocument(completion: $0) }
    }

    func saveDocument(to url: URL, format: CaptureFileFormat) async {
        await waitForCompletion { saveDocument(to: url, format: format, completion: $0) }
    }

    func exportSession(to url: URL, format: CaptureFileFormat) async -> Result<Void, Error> {
        await waitForResult { exportSession(to: url, format: format, completion: $0) }
    }

    func exportPackets(_ identifiers: [PacketSummary.ID], to url: URL, format: CaptureFileFormat) async -> Result<Void, Error> {
        await waitForResult { exportPackets(identifiers, to: url, format: format, completion: $0) }
    }

    func exportSourceList(_ selection: PacketSourceListSelection, to url: URL, format: CaptureFileFormat) async -> Result<Void, Error> {
        await waitForResult { exportSourceList(selection, to: url, format: format, completion: $0) }
    }
}

private func waitForCompletion(_ start: (@escaping () -> Void) -> Void) async {
    await withCheckedContinuation { continuation in
        start {
            continuation.resume()
        }
    }
}

private func waitForResult(_ start: (@escaping TCPViewerVoidCompletion) -> Void) async -> Result<Void, Error> {
    await withCheckedContinuation { continuation in
        start { result in
            continuation.resume(returning: result)
        }
    }
}
