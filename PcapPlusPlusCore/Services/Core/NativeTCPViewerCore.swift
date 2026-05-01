import Foundation
@_implementationOnly import TCPViewerNativeBridge

public final class NativeTCPViewerCore: TCPViewerCoreProviding, @unchecked Sendable {
    private static let defaultQueueLabel = "com.proxyman.tcpviewer.PcapPlusPlusCore.NativeTCPViewerCore"

    private let nativeCore: PCPPNativeCore
    private let workerQueue: DispatchQueue
    private let disablesWiresharkForOfflineDocuments: Bool
    private let disablesWiresharkForLiveSessions: Bool

    public init() {
        self.nativeCore = PCPPNativeCore()
        self.workerQueue = DispatchQueue(label: Self.defaultQueueLabel, qos: .userInitiated)
        self.disablesWiresharkForOfflineDocuments = false
        self.disablesWiresharkForLiveSessions = false
    }

    init(
        nativeCore: PCPPNativeCore,
        workerQueue: DispatchQueue = DispatchQueue(label: NativeTCPViewerCore.defaultQueueLabel, qos: .userInitiated),
        disablesWiresharkForOfflineDocuments: Bool = false,
        disablesWiresharkForLiveSessions: Bool = false
    ) {
        self.nativeCore = nativeCore
        self.workerQueue = workerQueue
        self.disablesWiresharkForOfflineDocuments = disablesWiresharkForOfflineDocuments
        self.disablesWiresharkForLiveSessions = disablesWiresharkForLiveSessions
    }

    init(disablesWiresharkForOfflineDocuments: Bool, disablesWiresharkForLiveSessions: Bool = false) {
        self.nativeCore = PCPPNativeCore()
        self.workerQueue = DispatchQueue(label: Self.defaultQueueLabel, qos: .userInitiated)
        self.disablesWiresharkForOfflineDocuments = disablesWiresharkForOfflineDocuments
        self.disablesWiresharkForLiveSessions = disablesWiresharkForLiveSessions
    }

    public func listInterfaces(completion: @escaping TCPViewerCompletion<[CaptureInterfaceSummary]>) {
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

    public func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions, completion: @escaping TCPViewerCompletion<any LiveCaptureSessionProviding>) {
        workerQueue.async {
            completion(Result {
                let interfaces = try self.listInterfacesNow()
                guard let interface = interfaces.first(where: { $0.id == interfaceID }) else {
                    throw TCPViewerCoreError(
                        code: .unsupportedInterface,
                        message: "The selected capture interface is no longer present."
                    )
                }

                guard interface.isSelectable else {
                    throw TCPViewerCoreError(
                        code: .unsupportedInterface,
                        message: interface.availabilityReason ?? "The selected capture interface is not currently available."
                    )
                }

                let validatedOptions = try self.validateCaptureOptions(options, for: interface)
                if let expression = validatedOptions.captureFilterExpression {
                    let validation = self.validateCaptureFilterNow(expression)
                    guard validation.disposition == .valid else {
                        throw TCPViewerCoreError(
                            code: .invalidCaptureFilter,
                            message: validation.message ?? "TCP Viewer could not compile this capture filter."
                        )
                    }
                }
                return try NativeLiveCaptureSession(
                    interfaceID: interfaceID,
                    options: validatedOptions,
                    disablesWireshark: self.disablesWiresharkForLiveSessions
                )
            })
        }
    }

    public func supportedOfflineFormats() -> [CaptureFileFormat] {
        let formats = nativeCore.supportedOfflineFormats().compactMap(NativeBridgeMapper.captureFileFormat)
        return formats.isEmpty ? CaptureFileFormat.allCases : formats
    }

    public func openOfflineCaptureDocument(at fileURL: URL, completion: @escaping TCPViewerCompletion<any OfflineCaptureDocumentProviding>) {
        workerQueue.async {
            completion(Result {
                do {
                    return try NativeOfflineCaptureDocument(
                        fileURL: fileURL,
                        disablesWireshark: self.disablesWiresharkForOfflineDocuments
                    )
                } catch {
                    throw NativeBridgeMapper.coreError(error, defaultCode: .offlineFileOpenFailed)
                }
            })
        }
    }

    public func loadPacketSummaries(from fileURL: URL, completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
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
