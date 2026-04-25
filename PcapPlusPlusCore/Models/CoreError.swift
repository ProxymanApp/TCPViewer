import Foundation

public struct TCPViewerCoreError: Error, Sendable, Codable, Hashable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Codable {
        case integrationMisconfigured
        case interfaceDiscoveryFailed
        case capturePermissionDenied
        case invalidCaptureFilter
        case invalidCaptureOptions
        case malformedCapture
        case unsupportedInterface
        case liveSessionStartFailed
        case liveSessionControlFailed
        case offlineFileOpenFailed
        case offlineFileSaveFailed
        case writerFailure
        case operationCancelled
        case unavailableFeature
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String {
        "\(code.rawValue): \(message)"
    }
}
