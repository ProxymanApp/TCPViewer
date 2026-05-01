//
//  CaptureOptionsModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Foundation

public struct CaptureFilterValidation: Sendable, Codable, Hashable {
    public enum Disposition: String, Sendable, Codable {
        case valid
        case invalid
        case unavailable
    }

    public let disposition: Disposition
    public let normalizedExpression: String?
    public let message: String?

    public init(
        disposition: Disposition,
        normalizedExpression: String? = nil,
        message: String? = nil
    ) {
        self.disposition = disposition
        self.normalizedExpression = normalizedExpression
        self.message = message
    }
}

public enum CaptureStopCondition: Sendable, Codable, Hashable {
    case manual
    case packetCount(UInt64)
    case durationMilliseconds(UInt64)
}

public struct CaptureFileWriting: Sendable, Codable, Hashable {
    public enum Mode: String, Sendable, Codable {
        case disabled
        case single
        case rotating
        case ring
    }

    public let mode: Mode
    public let directoryURL: URL?
    public let fileNameStem: String?
    public let format: CaptureFileFormat?
    public let maxFileSizeBytes: UInt64?
    public let ringFileCount: Int?

    public init(
        mode: Mode,
        directoryURL: URL? = nil,
        fileNameStem: String? = nil,
        format: CaptureFileFormat? = nil,
        maxFileSizeBytes: UInt64? = nil,
        ringFileCount: Int? = nil
    ) {
        self.mode = mode
        self.directoryURL = directoryURL
        self.fileNameStem = fileNameStem
        self.format = format
        self.maxFileSizeBytes = maxFileSizeBytes
        self.ringFileCount = ringFileCount
    }

    public static let disabled = CaptureFileWriting(mode: .disabled)
}

public struct CaptureOptions: Sendable, Codable, Hashable {
    public let promiscuousMode: Bool
    public let snapshotLength: Int
    public let kernelBufferSizeBytes: Int
    public let readTimeoutMilliseconds: Int
    public let captureFilterExpression: String?
    public let stopCondition: CaptureStopCondition
    public let fileWriting: CaptureFileWriting

    public init(
        promiscuousMode: Bool,
        snapshotLength: Int,
        kernelBufferSizeBytes: Int,
        readTimeoutMilliseconds: Int,
        captureFilterExpression: String? = nil,
        stopCondition: CaptureStopCondition,
        fileWriting: CaptureFileWriting = .disabled
    ) {
        self.promiscuousMode = promiscuousMode
        self.snapshotLength = snapshotLength
        self.kernelBufferSizeBytes = kernelBufferSizeBytes
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.captureFilterExpression = captureFilterExpression
        self.stopCondition = stopCondition
        self.fileWriting = fileWriting
    }

    public static func defaults(for interface: CaptureInterfaceSummary? = nil) -> CaptureOptions {
        CaptureOptions(
            promiscuousMode: defaultPromiscuousMode(for: interface),
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 4 * 1024 * 1024,
            readTimeoutMilliseconds: 250,
            captureFilterExpression: nil,
            stopCondition: .manual,
            fileWriting: .disabled
        )
    }

    public func validated(for interface: CaptureInterfaceSummary? = nil) throws -> CaptureOptions {
        guard snapshotLength > 0 else {
            throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Snapshot length must be greater than zero.")
        }

        guard kernelBufferSizeBytes >= 0 else {
            throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Kernel buffer size cannot be negative.")
        }

        guard readTimeoutMilliseconds >= 0 else {
            throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Read timeout cannot be negative.")
        }

        switch stopCondition {
        case .manual:
            break
        case .packetCount(let count):
            guard count > 0 else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Packet-count stop conditions must be greater than zero.")
            }
        case .durationMilliseconds(let duration):
            guard duration > 0 else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Duration stop conditions must be greater than zero.")
            }
        }

        switch fileWriting.mode {
        case .disabled:
            break
        case .single:
            guard fileWriting.directoryURL != nil else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Single-file capture writing needs a directory.")
            }
            guard !(fileWriting.fileNameStem?.isEmpty ?? true) else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Single-file capture writing needs a filename stem.")
            }
            guard fileWriting.format != nil else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Single-file capture writing needs an output format.")
            }
        case .rotating:
            guard fileWriting.directoryURL != nil else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Rotating capture writing needs a directory.")
            }
            guard !(fileWriting.fileNameStem?.isEmpty ?? true) else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Rotating capture writing needs a filename stem.")
            }
            guard fileWriting.format != nil else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Rotating capture writing needs an output format.")
            }
            guard (fileWriting.maxFileSizeBytes ?? 0) > 0 else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Rotating capture writing needs a max file size.")
            }
        case .ring:
            guard fileWriting.directoryURL != nil else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs a directory.")
            }
            guard !(fileWriting.fileNameStem?.isEmpty ?? true) else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs a filename stem.")
            }
            guard fileWriting.format != nil else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs an output format.")
            }
            guard (fileWriting.maxFileSizeBytes ?? 0) > 0 else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs a max file size.")
            }
            guard (fileWriting.ringFileCount ?? 0) > 1 else {
                throw TCPViewerCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs at least two files.")
            }
        }

        let validatedPromiscuousMode = Self.validatedPromiscuousMode(promiscuousMode, for: interface)
        if validatedPromiscuousMode != promiscuousMode {
            return CaptureOptions(
                promiscuousMode: validatedPromiscuousMode,
                snapshotLength: snapshotLength,
                kernelBufferSizeBytes: kernelBufferSizeBytes,
                readTimeoutMilliseconds: readTimeoutMilliseconds,
                captureFilterExpression: captureFilterExpression,
                stopCondition: stopCondition,
                fileWriting: fileWriting
            )
        }

        return self
    }

    private static func defaultPromiscuousMode(for interface: CaptureInterfaceSummary?) -> Bool {
        guard let interface else {
            return false
        }

        return !interface.isLoopback && interface.capabilities.supportsPromiscuousMode
    }

    private static func validatedPromiscuousMode(_ requestedMode: Bool, for interface: CaptureInterfaceSummary?) -> Bool {
        guard requestedMode, let interface else {
            return false
        }

        return !interface.isLoopback && interface.capabilities.supportsPromiscuousMode
    }
}
