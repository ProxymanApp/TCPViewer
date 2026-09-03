//
//  EndpointStatisticsCancellationToken.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Foundation

final class EndpointStatisticsCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    #if DEBUG
    private var remainingChecksBeforeCancellation: Int?
    #endif

    init() {}

    #if DEBUG
    init(cancelAfterCheckCount: Int) {
        precondition(cancelAfterCheckCount >= 0)
        remainingChecksBeforeCancellation = cancelAfterCheckCount
    }
    #endif

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        #if DEBUG
        if !cancelled, let remainingChecksBeforeCancellation {
            if remainingChecksBeforeCancellation == 0 {
                cancelled = true
            } else {
                self.remainingChecksBeforeCancellation = remainingChecksBeforeCancellation - 1
            }
        }
        #endif
        return cancelled
    }
}

enum EndpointStatisticsConsumeResult: Equatable {
    case consumed
    case rejected
    case cancelled
}
