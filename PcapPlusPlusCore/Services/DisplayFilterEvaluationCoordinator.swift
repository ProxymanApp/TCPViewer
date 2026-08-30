//
//  DisplayFilterEvaluationCoordinator.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation

enum DisplayFilterEvaluationCoordinator {
    private static let lock = NSLock()

    static func perform<Value>(_ work: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}
