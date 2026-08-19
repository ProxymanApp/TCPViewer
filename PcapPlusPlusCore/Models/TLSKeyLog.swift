//
//  TLSKeyLog.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/8/26.
//

import Foundation

public struct TLSKeyLogValidation: Sendable, Equatable {
    public let validRecordCount: Int
    public let warningCount: Int
    public let scannedLineCount: Int
    public let reachedScanLimit: Bool

    public init(validRecordCount: Int, warningCount: Int, scannedLineCount: Int, reachedScanLimit: Bool) {
        self.validRecordCount = validRecordCount
        self.warningCount = warningCount
        self.scannedLineCount = scannedLineCount
        self.reachedScanLimit = reachedScanLimit
    }
}
public struct TLSKeyLogState: Sendable, Equatable {
    public let fileURL: URL?
    public let validation: TLSKeyLogValidation?
    public let configurationGeneration: UInt64

    public init(fileURL: URL?, validation: TLSKeyLogValidation?, configurationGeneration: UInt64) {
        self.fileURL = fileURL
        self.validation = validation
        self.configurationGeneration = configurationGeneration
    }

    public static let empty = TLSKeyLogState(fileURL: nil, validation: nil, configurationGeneration: 0)
}

public protocol TLSKeyLogManaging: AnyObject {
    func validate(fileURL: URL, completion: @escaping TCPViewerCompletion<TLSKeyLogValidation>)
    func apply(fileURL: URL, completion: @escaping TCPViewerCompletion<TLSKeyLogState>)
    func remove(completion: @escaping TCPViewerCompletion<TLSKeyLogState>)
    func currentState(completion: @escaping (TLSKeyLogState) -> Void)
}
