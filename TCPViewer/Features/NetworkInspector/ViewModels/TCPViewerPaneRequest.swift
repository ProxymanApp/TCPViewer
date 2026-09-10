//
//  TCPViewerPaneRequest.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import Foundation
import PcapPlusPlusCore

/// Drops a caller's completion on cancellation even when native work is still draining.
final class TCPViewerPaneRequest<Value> {
    private let lock = NSLock()
    private var completion: TCPViewerCompletion<Value>?

    init(completion: @escaping TCPViewerCompletion<Value>) { self.completion = completion }

    // Clear before calling out: completion can synchronously close the tab again.
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(result)
    }

    func cancel() {
        finish(.failure(TCPViewerCoreError(code: .operationCancelled, message: "The tab was closed.")))
    }
}
