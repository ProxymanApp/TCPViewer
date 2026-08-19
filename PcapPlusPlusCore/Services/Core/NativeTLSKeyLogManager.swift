//
//  NativeTLSKeyLogManager.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/8/26.
//

import Foundation
@_implementationOnly import TCPViewerWiresharkEpanShim

public final class NativeTLSKeyLogManager: TLSKeyLogManaging, @unchecked Sendable {
    private enum Limits {
        static let maximumBytes = 4 * 1_024 * 1_024
        static let maximumLineCount = 20_000
        static let readChunkSize = 64 * 1_024
    }

    private let queue: DispatchQueue
    private let runtimeConfiguration: WiresharkRuntimeConfiguration
    private var state = TLSKeyLogState.empty

    public init() {
        self.queue = DispatchQueue(label: "com.proxyman.tcpviewer.PcapPlusPlusCore.TLSKeyLog", qos: .userInitiated)
        self.runtimeConfiguration = WiresharkRuntimeConfiguration()
    }

    init(queue: DispatchQueue, runtimeConfiguration: WiresharkRuntimeConfiguration) {
        self.queue = queue
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func validate(fileURL: URL, completion: @escaping TCPViewerCompletion<TLSKeyLogValidation>) {
        queue.async {
            completion(Result { try Self.validateFile(at: fileURL) })
        }
    }

    public func apply(fileURL: URL, completion: @escaping TCPViewerCompletion<TLSKeyLogState>) {
        queue.async {
            completion(Result {
                let validation = try Self.validateFile(at: fileURL)
                let generation = try self.configureWireshark(filePath: fileURL.path)
                let nextState = TLSKeyLogState(
                    fileURL: fileURL,
                    validation: validation,
                    configurationGeneration: generation
                )
                self.state = nextState
                return nextState
            })
        }
    }

    public func remove(completion: @escaping TCPViewerCompletion<TLSKeyLogState>) {
        queue.async {
            completion(Result {
                let generation = try self.configureWireshark(filePath: nil)
                let nextState = TLSKeyLogState(
                    fileURL: nil,
                    validation: nil,
                    configurationGeneration: generation
                )
                self.state = nextState
                return nextState
            })
        }
    }

    public func currentState(completion: @escaping (TLSKeyLogState) -> Void) {
        queue.async {
            completion(self.state)
        }
    }

    // Scan complete lines only because key-log producers can be appending the final record.
    static func validateFile(at fileURL: URL) throws -> TLSKeyLogValidation {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        } catch {
            throw invalidFile("TCP Viewer cannot access the selected TLS key-log file.")
        }
        guard values.isRegularFile == true else {
            throw invalidFile("Choose a regular TLS key-log file, not a directory.")
        }
        guard values.isReadable != false else {
            throw invalidFile("TCP Viewer cannot read the selected TLS key-log file.")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw invalidFile("TCP Viewer cannot read the selected TLS key-log file.")
        }
        defer { try? handle.close() }

        var pending = Data()
        var scannedBytes = 0
        var scannedLines = 0
        var validRecords = 0
        var warnings = 0
        var reachedLimit = false

        while scannedBytes < Limits.maximumBytes && scannedLines < Limits.maximumLineCount {
            let requestedCount = min(Limits.readChunkSize, Limits.maximumBytes - scannedBytes)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: requestedCount) ?? Data()
            } catch {
                throw invalidFile("TCP Viewer could not finish reading the selected TLS key-log file.")
            }
            guard !chunk.isEmpty else {
                break
            }
            scannedBytes += chunk.count
            pending.append(chunk)

            while scannedLines < Limits.maximumLineCount,
                  let newlineIndex = pending.firstIndex(of: 0x0A) {
                var line = pending[..<newlineIndex]
                if line.last == 0x0D {
                    line = line.dropLast()
                }
                pending.removeSubrange(...newlineIndex)
                scannedLines += 1
                switch classify(line: line) {
                case .ignored:
                    break
                case .valid:
                    validRecords += 1
                case .warning:
                    warnings += 1
                }
            }
        }

        if scannedBytes == Limits.maximumBytes || scannedLines == Limits.maximumLineCount {
            reachedLimit = true
        }
        guard validRecords > 0 else {
            throw invalidFile("No key records recognized by this Wireshark build were found. Syntax validation cannot prove that keys match a capture.")
        }
        return TLSKeyLogValidation(
            validRecordCount: validRecords,
            warningCount: warnings,
            scannedLineCount: scannedLines,
            reachedScanLimit: reachedLimit
        )
    }

    private enum LineClassification {
        case ignored
        case valid
        case warning
    }

    private static func classify(line: Data.SubSequence) -> LineClassification {
        guard let value = String(data: Data(line), encoding: .utf8) else {
            return .warning
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            return .ignored
        }

        if trimmed.hasPrefix("RSA Session-ID:") {
            return validateRSASessionLine(trimmed) ? .valid : .warning
        }
        let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 3 else {
            return .warning
        }
        let label = fields[0]
        let identifier = fields[1]
        let secret = fields[2]
        guard isEvenHex(identifier), isEvenHex(secret) else {
            return .warning
        }

        switch label {
        case "PMS_CLIENT_RANDOM":
            return identifier.count == 64 ? .valid : .warning
        case "RSA":
            return identifier.count == 16 ? .valid : .warning
        case "CLIENT_RANDOM":
            return identifier.count == 64 && secret.count == 96 ? .valid : .warning
        case "CLIENT_EARLY_TRAFFIC_SECRET", "CLIENT_HANDSHAKE_TRAFFIC_SECRET",
             "SERVER_HANDSHAKE_TRAFFIC_SECRET", "CLIENT_TRAFFIC_SECRET_0",
             "SERVER_TRAFFIC_SECRET_0", "EARLY_EXPORTER_SECRET", "EXPORTER_SECRET":
            return identifier.count == 64 ? .valid : .warning
        case "ECH_SECRET":
            return (64...128).contains(identifier.count) ? .valid : .warning
        case "ECH_CONFIG":
            return identifier.count >= 44 ? .valid : .warning
        default:
            return .warning
        }
    }

    private static func validateRSASessionLine(_ value: String) -> Bool {
        let prefix = "RSA Session-ID:"
        let separator = " Master-Key:"
        guard let separatorRange = value.range(of: separator) else {
            return false
        }
        let sessionID = String(value[value.index(value.startIndex, offsetBy: prefix.count)..<separatorRange.lowerBound])
        let masterKey = String(value[separatorRange.upperBound...])
        return isEvenHex(sessionID) && masterKey.count == 96 && isEvenHex(masterKey)
    }

    private static func isEvenHex(_ value: String) -> Bool {
        !value.isEmpty && value.count.isMultiple(of: 2) && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private func configureWireshark(filePath: String?) throws -> UInt64 {
        let directory: URL
        do {
            directory = try runtimeConfiguration.createPersonalConfigurationDirectoryIfNeeded()
        } catch {
            throw Self.invalidFile("TCP Viewer could not prepare its Wireshark runtime.")
        }

        var generation: UInt64 = 0
        var errorPointer: UnsafeMutablePointer<CChar>?
        let succeeded = directory.path.withCString { directoryPath in
            guard let filePath else {
                return TCPViewerWiresharkConfigureTLSKeyLog(nil, directoryPath, &generation, &errorPointer)
            }
            return filePath.withCString { path in
                TCPViewerWiresharkConfigureTLSKeyLog(path, directoryPath, &generation, &errorPointer)
            }
        }
        defer { TCPViewerWiresharkCStringDestroy(errorPointer) }
        guard succeeded else {
            let message = errorPointer.map { String(cString: $0) }
                ?? "Wireshark could not apply the TLS key-log file."
            throw Self.invalidFile(message)
        }
        return generation
    }

    private static func invalidFile(_ message: String) -> TCPViewerCoreError {
        TCPViewerCoreError(code: .unavailableFeature, message: message)
    }
}
