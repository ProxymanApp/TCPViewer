import Foundation

public typealias PacketryCompletion<Value> = (Result<Value, Error>) -> Void
public typealias PacketryVoidCompletion = (Result<Void, Error>) -> Void
public typealias PacketIngestEventHandler = (Result<PacketIngestEvent, Error>) -> Void

public protocol CaptureInterfaceProviding {
    func listInterfaces(completion: @escaping PacketryCompletion<[CaptureInterfaceSummary]>)
}

public protocol CaptureFilterValidating {
    func validateCaptureFilter(_ expression: String, completion: @escaping (CaptureFilterValidation) -> Void)
}

public protocol LiveCaptureSessionProviding: AnyObject {
    var eventHandler: PacketIngestEventHandler? { get set }

    func start(completion: @escaping PacketryVoidCompletion)
    func pause(completion: @escaping PacketryVoidCompletion)
    func resume(completion: @escaping PacketryVoidCompletion)
    func stop(completion: @escaping PacketryVoidCompletion)
    func inspectPacket(id: PacketSummary.ID, completion: @escaping PacketryCompletion<PacketInspection>)
    func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void)
}

public protocol OfflineCaptureDocumentProviding: AnyObject {
    var eventHandler: PacketIngestEventHandler? { get set }

    func open(completion: @escaping PacketryCompletion<[PacketSummary]>)
    func reopen(completion: @escaping PacketryCompletion<[PacketSummary]>)
    func cancelLoading(completion: (() -> Void)?)
    func inspectPacket(id: PacketSummary.ID, completion: @escaping PacketryCompletion<PacketInspection>)
    func save(completion: @escaping PacketryVoidCompletion)
    func save(to url: URL, format: CaptureFileFormat, completion: @escaping PacketryVoidCompletion)
    func currentURL() -> URL
    func currentMetadata() -> CaptureDocumentMetadata
    func packetSummaries() -> [PacketSummary]
    func loadProgress() -> PacketLoadProgress
}

public protocol LiveCaptureProviding {
    func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions
    func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions, completion: @escaping PacketryCompletion<any LiveCaptureSessionProviding>)
}

public protocol OfflineCaptureProviding {
    func supportedOfflineFormats() -> [CaptureFileFormat]
    func openOfflineCaptureDocument(at fileURL: URL, completion: @escaping PacketryCompletion<any OfflineCaptureDocumentProviding>)
    func loadPacketSummaries(from fileURL: URL, completion: @escaping PacketryCompletion<[PacketSummary]>)
}

public protocol PacketryCoreProviding:
    CaptureInterfaceProviding,
    CaptureFilterValidating,
    LiveCaptureProviding,
    OfflineCaptureProviding {}

public struct UnconfiguredPacketryCore: PacketryCoreProviding {
    public init() {}

    public func listInterfaces(completion: @escaping PacketryCompletion<[CaptureInterfaceSummary]>) {
        completion(.failure(PacketryCoreError(
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

    public func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions, completion: @escaping PacketryCompletion<any LiveCaptureSessionProviding>) {
        do {
            _ = try validateCaptureOptions(options, for: nil)
            completion(.failure(PacketryCoreError(
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

    public func openOfflineCaptureDocument(at fileURL: URL, completion: @escaping PacketryCompletion<any OfflineCaptureDocumentProviding>) {
        completion(.failure(PacketryCoreError(
            code: .integrationMisconfigured,
            message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent)."
        )))
    }

    public func loadPacketSummaries(from fileURL: URL, completion: @escaping PacketryCompletion<[PacketSummary]>) {
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

    public func start(completion: @escaping PacketryVoidCompletion) {
        completion(.failure(PacketryCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")))
    }

    public func pause(completion: @escaping PacketryVoidCompletion) {
        completion(.failure(PacketryCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")))
    }

    public func resume(completion: @escaping PacketryVoidCompletion) {
        completion(.failure(PacketryCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")))
    }

    public func stop(completion: @escaping PacketryVoidCompletion) {
        completion(.failure(PacketryCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")))
    }

    public func inspectPacket(id: PacketSummary.ID, completion: @escaping PacketryCompletion<PacketInspection>) {
        _ = id
        completion(.failure(PacketryCoreError(code: .integrationMisconfigured, message: "Packet inspection is not wired into PcapPlusPlusCore yet.")))
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

    public func open(completion: @escaping PacketryCompletion<[PacketSummary]>) {
        completion(.failure(PacketryCoreError(code: .integrationMisconfigured, message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")))
    }

    public func reopen(completion: @escaping PacketryCompletion<[PacketSummary]>) {
        open(completion: completion)
    }

    public func cancelLoading(completion: (() -> Void)?) {
        completion?()
    }

    public func inspectPacket(id: PacketSummary.ID, completion: @escaping PacketryCompletion<PacketInspection>) {
        _ = id
        completion(.failure(PacketryCoreError(code: .integrationMisconfigured, message: "Packet inspection is not wired into PcapPlusPlusCore yet.")))
    }

    public func save(completion: @escaping PacketryVoidCompletion) {
        completion(.failure(PacketryCoreError(code: .integrationMisconfigured, message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")))
    }

    public func save(to url: URL, format: CaptureFileFormat, completion: @escaping PacketryVoidCompletion) {
        _ = url
        _ = format
        completion(.failure(PacketryCoreError(code: .integrationMisconfigured, message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")))
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
