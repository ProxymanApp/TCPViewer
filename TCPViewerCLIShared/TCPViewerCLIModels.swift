//
//  TCPViewerCLIModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation

enum TCPViewerCLICommand: String, Codable, CaseIterable {
    case appStatus = "app.status"
    case interfacesList = "interfaces.list"
    case captureStatus = "capture.status"
    case captureStart = "capture.start"
    case capturePause = "capture.pause"
    case captureResume = "capture.resume"
    case captureStop = "capture.stop"
    case packetsList = "packets.list"
    case packetsSummary = "packets.summary"
    case packetsDetails = "packets.details"
    case packetsBytes = "packets.bytes"
    case packetsClear = "packets.clear"
    case packetsReveal = "packets.reveal"
    case streamPackets = "stream.packets"
    case streamFollow = "stream.follow"
    case fileImport = "file.import"
    case fileExport = "file.export"
    case fileExportSession = "file.export_session"
    case licenseStatus = "license.status"
    case licenseActivate = "license.activate"
    case licenseRevoke = "license.revoke"
    case settingsList = "settings.list"
    case settingsGet = "settings.get"
    case settingsSet = "settings.set"
    case settingsReset = "settings.reset"
}

enum TCPViewerCLIValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TCPViewerCLIValue])
    case object([String: TCPViewerCLIValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TCPViewerCLIValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: TCPViewerCLIValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported CLI JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value) where value.isFinite && value.rounded() == value:
            return Int(exactly: value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [TCPViewerCLIValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: TCPViewerCLIValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

struct TCPViewerCLIRequest: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let requestID: String
    let command: TCPViewerCLICommand
    let params: [String: TCPViewerCLIValue]
    let createdAt: Date
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
        case params
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    init(
        requestID: String = UUID().uuidString.lowercased(),
        command: TCPViewerCLICommand,
        params: [String: TCPViewerCLIValue] = [:],
        createdAt: Date = Date(),
        expiresAt: Date
    ) {
        self.schemaVersion = Self.schemaVersion
        self.requestID = requestID
        self.command = command
        self.params = params
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    func value(_ key: String) -> TCPViewerCLIValue? { params[key] }
    func string(_ key: String) -> String? { params[key]?.stringValue }
    func int(_ key: String) -> Int? { params[key]?.intValue }
    func bool(_ key: String) -> Bool? { params[key]?.boolValue }
    func array(_ key: String) -> [TCPViewerCLIValue]? { params[key]?.arrayValue }
}

struct TCPViewerCLIErrorPayload: Codable, Equatable {
    let code: String
    let message: String
}

struct TCPViewerCLIResponse: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let requestID: String
    let ok: Bool
    let command: TCPViewerCLICommand
    let data: [String: TCPViewerCLIValue]?
    let error: TCPViewerCLIErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case ok
        case command
        case data
        case error
    }

    static func success(
        requestID: String,
        command: TCPViewerCLICommand,
        data: [String: TCPViewerCLIValue]
    ) -> TCPViewerCLIResponse {
        TCPViewerCLIResponse(
            schemaVersion: schemaVersion,
            requestID: requestID,
            ok: true,
            command: command,
            data: data,
            error: nil
        )
    }

    static func failure(
        requestID: String,
        command: TCPViewerCLICommand,
        code: String,
        message: String,
        data: [String: TCPViewerCLIValue]? = nil
    ) -> TCPViewerCLIResponse {
        TCPViewerCLIResponse(
            schemaVersion: schemaVersion,
            requestID: requestID,
            ok: false,
            command: command,
            data: data,
            error: TCPViewerCLIErrorPayload(code: code, message: message)
        )
    }
}

extension TCPViewerCLIValue {
    // Keep filter input lexical because the app applies numeric conversion only for numeric operators.
    static func lexicalFilterValue(_ value: String) -> TCPViewerCLIValue {
        .string(value)
    }
}
