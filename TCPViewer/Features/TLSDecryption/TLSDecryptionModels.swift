//
//  TLSDecryptionModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import Foundation
import PcapPlusPlusCore

// Where the chosen key log file stands, as shown in Settings, the inspector and MCP.
enum TLSKeyLogStatus: Equatable {
    case notConfigured
    case reading
    case ready(TLSKeyLogSummary)
    case missing
    case unreadable(String)
    case notKeyLog

    var isProblem: Bool {
        switch self {
        case .missing, .unreadable, .notKeyLog:
            true
        case .notConfigured, .reading, .ready:
            false
        }
    }
}

enum TLSKeyLogFileError: LocalizedError, Equatable {
    case unreadable(fileName: String, reason: String)
    case notKeyLog(fileName: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let fileName, let reason):
            "TCP Viewer can't read “\(fileName)”. \(reason)"
        case .notKeyLog(let fileName):
            "“\(fileName)” isn't a TLS key log file. Choose the file Proxyman, your browser or curl writes with SSLKEYLOGFILE; each line starts with a label such as CLIENT_RANDOM."
        }
    }
}

extension TLSKeyLogSummary {
    // "2 TLS connections · 9 keys · 1.4 KB"
    var tcpviewerDescription: String {
        let connections = sessionCount == 1 ? "1 TLS connection" : "\(sessionCount.formatted()) TLS connections"
        let keys = keyCount == 1 ? "1 key" : "\(keyCount.formatted()) keys"
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: byteCount), countStyle: .file)
        return "\(connections) · \(keys) · \(size)"
    }
}

extension PacketSummary {
    // Wireshark still labels TLS records it could not decrypt "Application Data" (QUIC: "Protected Payload").
    var tcpviewerIsEncryptedTLSApplicationData: Bool {
        guard let protocolSummary else { return false }
        let isTLS = protocolSummary.hasPrefix("TLS") || protocolSummary.hasPrefix("SSL")
            || protocolSummary.hasPrefix("DTLS") || protocolSummary == "QUIC"
        return isTLS && (infoSummary.contains("Application Data") || infoSummary.contains("Protected Payload"))
    }
}

extension PacketSummaryUpdate {
    func tcpviewerRemapping(packetID: PacketSummary.ID) -> PacketSummaryUpdate {
        PacketSummaryUpdate(
            packetID: packetID,
            protocolSummary: protocolSummary,
            infoSummary: infoSummary,
            transportHint: transportHint
        )
    }
}

// What the inspector tells the user about TLS for the selected packet.
enum TLSInspectorNotice: Equatable {
    // Encrypted and no key log is in use: offer to add one.
    case encryptedWithoutKeyLog
    // Encrypted although a key log is in use: its keys or the handshake for this connection are missing.
    case encryptedWithKeyLog(fileName: String)
    // Decrypted; nil when the keys came from the capture file itself (a PCAPNG Decryption Secrets Block).
    case decrypted(keyLogFileName: String?)

    static func make(for inspection: PacketInspection?, activeKeyLogURL: URL?) -> TLSInspectorNotice? {
        guard let inspection else { return nil }
        let fileName = activeKeyLogURL?.lastPathComponent
        if inspection.byteViews.contains(where: { $0.label.hasPrefix("Decrypted TLS") || $0.label.hasPrefix("Decrypted QUIC") }) {
            return .decrypted(keyLogFileName: fileName)
        }
        guard containsEncryptedPayload(inspection.detailNodes) else {
            return nil
        }
        return fileName.map(TLSInspectorNotice.encryptedWithKeyLog) ?? .encryptedWithoutKeyLog
    }

    private static func containsEncryptedPayload(_ nodes: [PacketDetailNode]) -> Bool {
        nodes.contains { node in
            node.fieldName == "tls.app_data" || node.fieldName == "quic.protected_payload"
                || containsEncryptedPayload(node.children)
        }
    }
}
