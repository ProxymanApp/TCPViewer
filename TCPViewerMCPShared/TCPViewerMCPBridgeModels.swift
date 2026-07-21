//
//  TCPViewerMCPBridgeModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Darwin
import Foundation

enum TCPViewerMCPCommand: String, Codable, CaseIterable, Sendable {
    case getAppStatus = "get_app_status"
    case getCaptureOverview = "get_capture_overview"
    case listInterfaces = "list_interfaces"
    case queryPackets = "query_packets"
    case summarizeCapture = "summarize_capture"
    case getPacketDetails = "get_packet_details"
    case getPacketBytes = "get_packet_bytes"
    case listStreamPackets = "list_stream_packets"
    case exportPackets = "export_packets"
    case startCapture = "start_capture"
    case pauseCapture = "pause_capture"
    case resumeCapture = "resume_capture"
    case stopCapture = "stop_capture"
    case clearPackets = "clear_packets"
    case revealPacket = "reveal_packet"
}

enum TCPViewerMCPQueryLimit {
    static let maximumOffset = 100_000
    static let maximumProtocolCount = 100
    static let maximumDomainCount = 100
    static let maximumPacketIDCount = 10_000
}

struct TCPViewerMCPHandshake: Codable, Equatable, Sendable {
    static let applicationSupportDirectoryName = "TCPViewer"
    static let fileName = "mcp-handshake.json"

    let port: Int
    let token: String

    var isValid: Bool {
        (1...65_535).contains(port) && token.utf8.count >= 32
    }
}

enum TCPViewerMCPHandshakeFileError: Error {
    case unavailable
    case unsafeMetadata
}

enum TCPViewerMCPHandshakeFile {
    static let maximumByteCount = 4_096

    // Open once with O_NOFOLLOW, then validate and read that same file descriptor.
    static func readSecurely(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? TCPViewerMCPHandshakeFileError.unsafeMetadata : .unavailable
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw TCPViewerMCPHandshakeFileError.unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0,
              metadata.st_size >= 0,
              metadata.st_size <= maximumByteCount else {
            throw TCPViewerMCPHandshakeFileError.unsafeMetadata
        }

        var bytes = [UInt8](repeating: 0, count: maximumByteCount + 1)
        var byteCount = 0
        while byteCount < bytes.count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: byteCount),
                    buffer.count - byteCount
                )
            }
            if result < 0 && errno == EINTR {
                continue
            }
            guard result >= 0 else {
                throw TCPViewerMCPHandshakeFileError.unavailable
            }
            guard result > 0 else {
                break
            }
            byteCount += result
        }
        guard byteCount <= maximumByteCount else {
            throw TCPViewerMCPHandshakeFileError.unsafeMetadata
        }
        return Data(bytes.prefix(byteCount))
    }
}

struct TCPViewerMCPRequest: Codable, Equatable, Sendable {
    let command: String
    let params: [String: TCPViewerMCPValue]?

    init(command: String, params: [String: TCPViewerMCPValue]? = nil) {
        self.command = command
        self.params = params
    }

    func value(_ key: String) -> TCPViewerMCPValue? {
        params?[key]
    }

    func string(_ key: String) -> String? {
        params?[key]?.stringValue
    }

    func int(_ key: String) -> Int? {
        params?[key]?.intValue
    }

    func bool(_ key: String) -> Bool? {
        params?[key]?.boolValue
    }

    func array(_ key: String) -> [TCPViewerMCPValue]? {
        params?[key]?.arrayValue
    }
}

struct TCPViewerMCPResponse: Codable, Equatable, Sendable {
    let success: Bool
    let data: [String: TCPViewerMCPValue]?
    let error: String?

    static func success(_ data: [String: TCPViewerMCPValue]) -> TCPViewerMCPResponse {
        TCPViewerMCPResponse(success: true, data: data, error: nil)
    }

    static func failure(_ message: String) -> TCPViewerMCPResponse {
        TCPViewerMCPResponse(success: false, data: nil, error: message)
    }
}

enum TCPViewerMCPValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TCPViewerMCPValue])
    case object([String: TCPViewerMCPValue])
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
        } else if let value = try? container.decode([TCPViewerMCPValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: TCPViewerMCPValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported MCP bridge JSON value."
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
        guard case .string(let value) = self else {
            return nil
        }
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
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [TCPViewerMCPValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }

    var objectValue: [String: TCPViewerMCPValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    func jsonObject() -> Any {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .array(let values):
            return values.map { $0.jsonObject() }
        case .object(let values):
            return values.mapValues { $0.jsonObject() }
        case .null:
            return NSNull()
        }
    }
}

extension Dictionary where Key == String, Value == TCPViewerMCPValue {
    func jsonObject() -> [String: Any] {
        mapValues { $0.jsonObject() }
    }
}
