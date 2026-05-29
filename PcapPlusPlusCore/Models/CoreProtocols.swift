//
//  CoreProtocols.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Foundation

public typealias TCPViewerCompletion<Value> = (Result<Value, Error>) -> Void
public typealias TCPViewerVoidCompletion = (Result<Void, Error>) -> Void
public typealias PacketIngestEventHandler = (Result<PacketIngestEvent, Error>) -> Void
public typealias PacketExportProgressHandler = (PacketExportProgress) -> Void
public typealias PacketExportCancellationCheck = () -> Bool

public struct PacketExportProgress: Equatable, Sendable {
    public let exportedPacketCount: Int
    public let totalPacketCount: Int

    public init(exportedPacketCount: Int, totalPacketCount: Int) {
        self.exportedPacketCount = exportedPacketCount
        self.totalPacketCount = totalPacketCount
    }

    public var fractionCompleted: Double {
        guard totalPacketCount > 0 else {
            return 0
        }

        return min(max(Double(exportedPacketCount) / Double(totalPacketCount), 0), 1)
    }
}

#if DEBUG
public struct LiveCaptureSessionDebugSnapshot: Equatable, Sendable {
    public let pendingBatchCount: Int
    public let activeRunPacketCount: UInt64

    public static let empty = LiveCaptureSessionDebugSnapshot(
        pendingBatchCount: 0,
        activeRunPacketCount: 0
    )

    public init(pendingBatchCount: Int, activeRunPacketCount: UInt64) {
        self.pendingBatchCount = pendingBatchCount
        self.activeRunPacketCount = activeRunPacketCount
    }
}
#endif

public protocol CaptureInterfaceProviding {
    func listInterfaces(completion: @escaping TCPViewerCompletion<[CaptureInterfaceSummary]>)
}

public protocol CaptureFilterValidating {
    func validateCaptureFilter(_ expression: String, completion: @escaping (CaptureFilterValidation) -> Void)
}

public protocol LiveCaptureSessionProviding: AnyObject {
    var eventHandler: PacketIngestEventHandler? { get set }

    func start(completion: @escaping TCPViewerVoidCompletion)
    func pause(completion: @escaping TCPViewerVoidCompletion)
    func resume(completion: @escaping TCPViewerVoidCompletion)
    func stop(completion: @escaping TCPViewerVoidCompletion)
    func clearCapturedPackets(completion: @escaping TCPViewerVoidCompletion)
    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>)
    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    )
    func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void)
    #if DEBUG
    func debugMemorySnapshot() -> LiveCaptureSessionDebugSnapshot
    #endif
}

#if DEBUG
public extension LiveCaptureSessionProviding {
    func debugMemorySnapshot() -> LiveCaptureSessionDebugSnapshot {
        .empty
    }
}
#endif

public protocol OfflineCaptureDocumentProviding: AnyObject {
    var eventHandler: PacketIngestEventHandler? { get set }

    func open(completion: @escaping TCPViewerCompletion<[PacketSummary]>)
    func reopen(completion: @escaping TCPViewerCompletion<[PacketSummary]>)
    func cancelLoading(completion: (() -> Void)?)
    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>)
    func save(completion: @escaping TCPViewerVoidCompletion)
    func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion)
    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    )
    func currentURL() -> URL
    func currentMetadata() -> CaptureDocumentMetadata
    func packetSummaries() -> [PacketSummary]
    func loadProgress() -> PacketLoadProgress
}

public extension LiveCaptureSessionProviding {
    func exportPackets(withIDs identifiers: [PacketSummary.ID], to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        exportPackets(withIDs: identifiers, to: url, format: format, progress: nil, shouldCancel: nil, completion: completion)
    }
}

public extension OfflineCaptureDocumentProviding {
    func exportPackets(withIDs identifiers: [PacketSummary.ID], to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        exportPackets(withIDs: identifiers, to: url, format: format, progress: nil, shouldCancel: nil, completion: completion)
    }
}

public protocol LiveCaptureProviding {
    func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions
    func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions, completion: @escaping TCPViewerCompletion<any LiveCaptureSessionProviding>)
}

public protocol OfflineCaptureProviding {
    func supportedOfflineFormats() -> [CaptureFileFormat]
    func openOfflineCaptureDocument(at fileURL: URL, completion: @escaping TCPViewerCompletion<any OfflineCaptureDocumentProviding>)
    func loadPacketSummaries(from fileURL: URL, completion: @escaping TCPViewerCompletion<[PacketSummary]>)
}

public protocol TCPViewerCoreProviding:
    CaptureInterfaceProviding,
    CaptureFilterValidating,
    LiveCaptureProviding,
    OfflineCaptureProviding {}

public struct UnconfiguredTCPViewerCore: TCPViewerCoreProviding {
    public init() {}

    public func listInterfaces(completion: @escaping TCPViewerCompletion<[CaptureInterfaceSummary]>) {
        completion(.failure(TCPViewerCoreError(
            code: .integrationMisconfigured,
            message: "Native interface discovery is not wired into PcapPlusPlusCore yet."
        )))
    }

    public func validateCaptureFilter(_ expression: String, completion: @escaping (CaptureFilterValidation) -> Void) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            completion(CaptureFilterValidation(
                disposition: .invalid,
                normalizedExpression: nil,
                message: "Capture filters cannot be empty."
            ))
            return
        }

        completion(CaptureFilterValidation(
            disposition: .unavailable,
            normalizedExpression: trimmed,
            message: "Native capture-filter validation is not available in the unconfigured core."
        ))
    }

    public func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions {
        try options.validated(for: interface)
    }

    public func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions, completion: @escaping TCPViewerCompletion<any LiveCaptureSessionProviding>) {
        do {
            _ = try validateCaptureOptions(options, for: nil)
            completion(.failure(TCPViewerCoreError(
                code: .integrationMisconfigured,
                message: "Native live capture sessions are not wired into PcapPlusPlusCore yet."
            )))
        } catch {
            completion(.failure(error))
        }
    }

    public func supportedOfflineFormats() -> [CaptureFileFormat] {
        CaptureFileFormat.allCases
    }

    public func openOfflineCaptureDocument(at fileURL: URL, completion: @escaping TCPViewerCompletion<any OfflineCaptureDocumentProviding>) {
        completion(.failure(TCPViewerCoreError(
            code: .integrationMisconfigured,
            message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent)."
        )))
    }

    public func loadPacketSummaries(from fileURL: URL, completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        openOfflineCaptureDocument(at: fileURL) { result in
            switch result {
            case .success(let document):
                document.open(completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

public final class UnconfiguredLiveCaptureSession: LiveCaptureSessionProviding {
    public var eventHandler: PacketIngestEventHandler?

    public init() {}

    public func start(completion: @escaping TCPViewerVoidCompletion) {
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")))
    }

    public func pause(completion: @escaping TCPViewerVoidCompletion) {
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")))
    }

    public func resume(completion: @escaping TCPViewerVoidCompletion) {
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")))
    }

    public func stop(completion: @escaping TCPViewerVoidCompletion) {
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")))
    }

    public func clearCapturedPackets(completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    public func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        _ = id
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Packet inspection is not wired into PcapPlusPlusCore yet.")))
    }

    public func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        _ = identifiers
        _ = url
        _ = format
        _ = progress
        _ = shouldCancel
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Packet export is not wired into PcapPlusPlusCore yet.")))
    }

    public func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void) {
        completion(.empty)
    }
}

public final class UnconfiguredOfflineCaptureDocument: OfflineCaptureDocumentProviding {
    public var eventHandler: PacketIngestEventHandler?
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func open(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")))
    }

    public func reopen(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        open(completion: completion)
    }

    public func cancelLoading(completion: (() -> Void)?) {
        completion?()
    }

    public func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        _ = id
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Packet inspection is not wired into PcapPlusPlusCore yet.")))
    }

    public func save(completion: @escaping TCPViewerVoidCompletion) {
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")))
    }

    public func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        _ = url
        _ = format
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")))
    }

    public func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        _ = identifiers
        _ = url
        _ = format
        _ = progress
        _ = shouldCancel
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Packet export is not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")))
    }

    public func currentURL() -> URL {
        fileURL
    }

    public func currentMetadata() -> CaptureDocumentMetadata {
        CaptureDocumentMetadata(format: .pcapng)
    }

    public func packetSummaries() -> [PacketSummary] {
        []
    }

    public func loadProgress() -> PacketLoadProgress {
        .idle
    }
}
