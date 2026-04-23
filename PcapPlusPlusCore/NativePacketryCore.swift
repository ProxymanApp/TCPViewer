import Foundation
@_implementationOnly import PacketryNativeBridge

public final class NativePacketryCore: PacketryCoreProviding, @unchecked Sendable {
    private let nativeCore: PCPPNativeCore

    public init() {
        self.nativeCore = PCPPNativeCore()
    }

    init(nativeCore: PCPPNativeCore) {
        self.nativeCore = nativeCore
    }

    public func listInterfaces() async throws -> [CaptureInterfaceSummary] {
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

    public func validateCaptureFilter(_ expression: String) async -> CaptureFilterValidation {
        NativeBridgeMapper.filterValidation(nativeCore.validateCaptureFilter(expression))
    }

    public func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions {
        let normalized = options.normalizedForLiveCapture()
        return try normalized.validated(for: interface)
    }

    public func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions) async throws -> any LiveCaptureSessionProviding {
        let interfaces = try await listInterfaces()
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

        let validatedOptions = try validateCaptureOptions(options, for: interface)
        if let expression = validatedOptions.captureFilterExpression {
            let validation = await validateCaptureFilter(expression)
            guard validation.disposition == .valid else {
                throw PacketryCoreError(
                    code: .invalidCaptureFilter,
                    message: validation.message ?? "Packetry could not compile this capture filter."
                )
            }
        }
        return try NativeLiveCaptureSession(interfaceID: interfaceID, options: validatedOptions)
    }

    public func supportedOfflineFormats() -> [CaptureFileFormat] {
        let formats = nativeCore.supportedOfflineFormats().compactMap(NativeBridgeMapper.captureFileFormat)
        return formats.isEmpty ? CaptureFileFormat.allCases : formats
    }

    public func openOfflineCaptureDocument(at fileURL: URL) async throws -> any OfflineCaptureDocumentProviding {
        do {
            return try NativeOfflineCaptureDocument(fileURL: fileURL)
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .offlineFileOpenFailed)
        }
    }

    public func loadPacketSummaries(from fileURL: URL) async throws -> [PacketSummary] {
        let document = try await openOfflineCaptureDocument(at: fileURL)
        return try await document.open()
    }
}
