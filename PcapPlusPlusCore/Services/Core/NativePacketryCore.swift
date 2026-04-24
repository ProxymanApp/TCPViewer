import Foundation
@_implementationOnly import PacketryNativeBridge

public final class NativePacketryCore: PacketryCoreProviding, @unchecked Sendable {
    private static let defaultQueueLabel = "com.proxyman.Packetry.PcapPlusPlusCore.NativePacketryCore"

    private let nativeCore: PCPPNativeCore
    private let workerQueue: DispatchQueue

    public init() {
        self.nativeCore = PCPPNativeCore()
        self.workerQueue = DispatchQueue(label: Self.defaultQueueLabel, qos: .userInitiated)
    }

    init(
        nativeCore: PCPPNativeCore,
        workerQueue: DispatchQueue = DispatchQueue(label: NativePacketryCore.defaultQueueLabel, qos: .userInitiated)
    ) {
        self.nativeCore = nativeCore
        self.workerQueue = workerQueue
    }

    public func listInterfaces(completion: @escaping PacketryCompletion<[CaptureInterfaceSummary]>) {
        workerQueue.async {
            completion(Result {
                try self.listInterfacesNow()
            })
        }
    }

    public func validateCaptureFilter(_ expression: String, completion: @escaping (CaptureFilterValidation) -> Void) {
        workerQueue.async {
            completion(self.validateCaptureFilterNow(expression))
        }
    }

    public func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions {
        let normalized = options.normalizedForLiveCapture()
        return try normalized.validated(for: interface)
    }

    public func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions, completion: @escaping PacketryCompletion<any LiveCaptureSessionProviding>) {
        workerQueue.async {
            completion(Result {
                let interfaces = try self.listInterfacesNow()
                guard let interface = interfaces.first(where: { $0.id == interfaceID }) else {
                    throw PacketryCoreError(
                        code: .unsupportedInterface,
                        message: "The selected capture interface is no longer present."
                    )
                }

                guard interface.isSelectable else {
                    throw PacketryCoreError(
                        code: .unsupportedInterface,
                        message: interface.availabilityReason ?? "The selected capture interface is not currently available."
                    )
                }

                let validatedOptions = try self.validateCaptureOptions(options, for: interface)
                if let expression = validatedOptions.captureFilterExpression {
                    let validation = self.validateCaptureFilterNow(expression)
                    guard validation.disposition == .valid else {
                        throw PacketryCoreError(
                            code: .invalidCaptureFilter,
                            message: validation.message ?? "Packetry could not compile this capture filter."
                        )
                    }
                }
                return try NativeLiveCaptureSession(interfaceID: interfaceID, options: validatedOptions)
            })
        }
    }

    public func supportedOfflineFormats() -> [CaptureFileFormat] {
        let formats = nativeCore.supportedOfflineFormats().compactMap(NativeBridgeMapper.captureFileFormat)
        return formats.isEmpty ? CaptureFileFormat.allCases : formats
    }

    public func openOfflineCaptureDocument(at fileURL: URL, completion: @escaping PacketryCompletion<any OfflineCaptureDocumentProviding>) {
        workerQueue.async {
            completion(Result {
                do {
                    return try NativeOfflineCaptureDocument(fileURL: fileURL)
                } catch {
                    throw NativeBridgeMapper.coreError(error, defaultCode: .offlineFileOpenFailed)
                }
            })
        }
    }

    public func loadPacketSummaries(from fileURL: URL, completion: @escaping PacketryCompletion<[PacketSummary]>) {
        openOfflineCaptureDocument(at: fileURL) { result in
            switch result {
            case .success(let document):
                document.open { result in
                    _ = document
                    completion(result)
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func listInterfacesNow() throws -> [CaptureInterfaceSummary] {
        do {
            var nativeError: NSError?
            let interfaces = nativeCore.discoverInterfacesAndReturnError(&nativeError).map(NativeBridgeMapper.interfaceSummary)
            if let nativeError {
                throw nativeError
            }
            return NativeBridgeMapper.sortedInterfaces(interfaces)
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .interfaceDiscoveryFailed)
        }
    }

    private func validateCaptureFilterNow(_ expression: String) -> CaptureFilterValidation {
        NativeBridgeMapper.filterValidation(nativeCore.validateCaptureFilter(expression))
    }
}
