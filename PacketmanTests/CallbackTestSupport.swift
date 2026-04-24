import Foundation
import PcapPlusPlusCore
@testable import Packetman

extension PacketryWindowController {
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
}

private func waitForCompletion(_ start: (@escaping () -> Void) -> Void) async {
    await withCheckedContinuation { continuation in
        start {
            continuation.resume()
        }
    }
}
