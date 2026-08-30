//
//  DisplayFilterModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation

public struct DisplayFilterSourceRange: Equatable, Sendable {
    public let utf8StartOffset: Int
    public let utf8Length: Int

    public init(utf8StartOffset: Int, utf8Length: Int) {
        self.utf8StartOffset = max(0, utf8StartOffset)
        self.utf8Length = max(0, utf8Length)
    }
}

public enum DisplayFilterDiagnosticSeverity: String, Equatable, Sendable {
    case warning
    case error
}

public struct DisplayFilterDiagnostic: Equatable, Sendable {
    public let severity: DisplayFilterDiagnosticSeverity
    public let message: String
    public let range: DisplayFilterSourceRange?

    public init(
        severity: DisplayFilterDiagnosticSeverity,
        message: String,
        range: DisplayFilterSourceRange? = nil
    ) {
        self.severity = severity
        self.message = message
        self.range = range
    }
}

public enum DisplayFilterValidationStatus: String, Equatable, Sendable {
    case valid
    case invalid
    case unavailable
}

public struct DisplayFilterValidation: Equatable, Sendable {
    public let normalizedExpression: String
    public let status: DisplayFilterValidationStatus
    public let diagnostics: [DisplayFilterDiagnostic]

    public init(
        normalizedExpression: String,
        status: DisplayFilterValidationStatus,
        diagnostics: [DisplayFilterDiagnostic] = []
    ) {
        self.normalizedExpression = normalizedExpression
        self.status = status
        self.diagnostics = diagnostics
    }

    public var isApplicable: Bool {
        status == .valid
    }
}

public struct DisplayFilterMatchBatch: Equatable, Sendable {
    public let generation: UInt64
    public let evaluatedPacketIDs: [PacketSummary.ID]
    public let matchingPacketIDs: [PacketSummary.ID]

    public init(
        generation: UInt64,
        evaluatedPacketIDs: [PacketSummary.ID],
        matchingPacketIDs: [PacketSummary.ID]
    ) {
        self.generation = generation
        self.evaluatedPacketIDs = evaluatedPacketIDs
        self.matchingPacketIDs = matchingPacketIDs
    }
}
