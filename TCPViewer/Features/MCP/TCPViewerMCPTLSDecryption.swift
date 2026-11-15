//
//  TCPViewerMCPTLSDecryption.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import Foundation
import PcapPlusPlusCore

// MCP access to the app-wide TLS key log: read its state, or change it and dissect open captures again.
enum TCPViewerMCPTLSDecryption {
    private static let maximumPathLength = 4_096

    // Answer on the main thread, where the store lives.
    static func route(
        _ command: TCPViewerMCPCommand,
        request: TCPViewerMCPRequest,
        store: TLSDecryptionStore,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        switch command {
        case .getTLSDecryption:
            completion(.success(state(store)))
        case .updateTLSDecryption:
            update(request, store: store, completion: completion)
        default:
            completion(.failure("Unsupported TLS decryption command."))
        }
    }

    static func state(_ store: TLSDecryptionStore) -> [String: TCPViewerMCPValue] {
        var data: [String: TCPViewerMCPValue] = [
            "enabled": .bool(store.isEnabled),
            "decrypting": .bool(store.activeKeyLogFileURL != nil && !store.status.isProblem),
            "key_log": store.keyLogFileURL.map { .object(keyLog($0, status: store.status)) } ?? .null,
            "note": .string(
                "TCP Viewer decrypts TLS, DTLS and QUIC with an NSS key log (SSLKEYLOGFILE), e.g. from Proxyman's Tools > TLS Key Logging. "
                    + "Decrypted packets show their inner protocol (HTTP, HTTP2, ...) in query_packets and get_packet_details. "
                    + "A change dissects open captures again; a running live capture uses new keys for new connections and is dissected again when it stops."
            ),
        ]
        if store.keyLogFileURL == nil {
            data["next_step"] = .string("Call update_tls_decryption with key_log_path set to the absolute path of a key log file.")
        }
        return data
    }

    // Check the arguments first. A new key log is read before it is used, so a rejected file changes nothing;
    // `enabled` applies after it because using a key log turns decryption on.
    private static func update(
        _ request: TCPViewerMCPRequest,
        store: TLSDecryptionStore,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        let path = request.string("key_log_path")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = request.bool("enabled")
        let decryptsAgain = request.bool("decrypt_open_captures_again") == true
        guard path != nil || enabled != nil || decryptsAgain else {
            completion(.failure("Pass key_log_path, enabled or decrypt_open_captures_again."))
            return
        }
        let applyOtherChanges = {
            if let enabled {
                store.setEnabled(enabled)
            }
            if decryptsAgain {
                store.decryptOpenCapturesAgain()
            }
        }
        guard let path, !path.isEmpty else {
            if path != nil {
                store.removeKeyLogFile()
            }
            applyOtherChanges()
            completion(.success(state(store)))
            return
        }
        guard path.utf8.count <= maximumPathLength, !path.contains("\0"), (path as NSString).isAbsolutePath else {
            completion(.failure("key_log_path must be an absolute file path, or an empty string to remove the key log."))
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            completion(.failure("No key log file exists at key_log_path."))
            return
        }
        store.useKeyLogFile(at: URL(fileURLWithPath: path)) { result in
            switch result {
            case .success:
                applyOtherChanges()
                completion(.success(state(store)))
            case .failure(let error):
                completion(.failure(error.localizedDescription))
            }
        }
    }

    private static func keyLog(_ url: URL, status: TLSKeyLogStatus) -> [String: TCPViewerMCPValue] {
        var data: [String: TCPViewerMCPValue] = [
            "path": .string(url.path),
            "file_name": .string(url.lastPathComponent),
        ]
        switch status {
        case .ready(let summary):
            data["status"] = .string(summary.keyCount == 0 ? "waiting_for_keys" : "ready")
            data["tls_connection_count"] = .int(summary.sessionCount)
            data["key_count"] = .int(summary.keyCount)
            data["byte_count"] = .int(Int(clamping: summary.byteCount))
            if summary.invalidLineCount > 0 {
                data["skipped_line_count"] = .int(summary.invalidLineCount)
            }
        case .reading:
            data["status"] = .string("reading")
        case .notConfigured:
            data["status"] = .string("not_configured")
        case .missing:
            data["status"] = .string("missing")
            data["message"] = .string("The key log file was moved or deleted.")
        case .unreadable(let reason):
            data["status"] = .string("unreadable")
            data["message"] = .string(reason)
        case .notKeyLog:
            data["status"] = .string("not_key_log")
            data["message"] = .string("The file no longer looks like a TLS key log.")
        }
        return data
    }
}
