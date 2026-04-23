import Combine
import Foundation
import PcapPlusPlusCore

struct CaptureDocumentState: Sendable, Equatable {
    enum Phase: String, Sendable {
        case idle
        case opening
        case loaded
        case dirty
        case failed
    }

    var phase: Phase
    var fileURL: URL?
    var packetCount: Int
    var statusMessage: String

    static let idle = CaptureDocumentState(
        phase: .idle,
        fileURL: nil,
        packetCount: 0,
        statusMessage: "Open a capture file or configure live capture to begin."
    )

    var canReopen: Bool {
        fileURL != nil && phase != .opening
    }
}

struct CaptureSessionState: Sendable, Equatable {
    enum Phase: String, Sendable {
        case idle
        case ready
        case starting
        case running
        case paused
        case stopping
        case failed
    }

    var phase: Phase
    var selectedInterfaceID: String?
    var capturedPacketCount: Int
    var statusMessage: String
    var lastError: PacketryCoreError?

    static let idle = CaptureSessionState(
        phase: .idle,
        selectedInterfaceID: nil,
        capturedPacketCount: 0,
        statusMessage: "Live capture is not configured yet.",
        lastError: nil
    )

    var isActive: Bool {
        switch phase {
        case .starting, .running, .stopping:
            true
        case .idle, .ready, .paused, .failed:
            false
        }
    }
}

struct PacketryWindowSnapshot: Sendable, Equatable {
    var accessState: CaptureAccessState
    var documentState: CaptureDocumentState
    var sessionState: CaptureSessionState
    var visiblePacketCount: Int
    var selectedPacketID: PacketSummary.ID?

    static let foundation = PacketryWindowSnapshot(
        accessState: .blocked(.firstLaunch),
        documentState: .idle,
        sessionState: .idle,
        visiblePacketCount: 0,
        selectedPacketID: nil
    )
}

actor PacketryBackgroundCoordinator {
    private var activeOperations: Set<String> = []

    func beginOperation(_ identifier: String) {
        activeOperations.insert(identifier)
    }

    func endOperation(_ identifier: String) {
        activeOperations.remove(identifier)
    }

    func cancelAll() {
        activeOperations.removeAll()
    }

    func activeOperationCount() -> Int {
        activeOperations.count
    }
}

struct PacketryServiceRegistry {
    let core: any PacketryCoreProviding

    init(core: any PacketryCoreProviding = UnconfiguredPacketryCore()) {
        self.core = core
    }

    static let foundation = PacketryServiceRegistry()
}

@MainActor
final class PacketryWindowController: ObservableObject {
    @Published private(set) var snapshot: PacketryWindowSnapshot

    let services: PacketryServiceRegistry
    private let backgroundCoordinator: PacketryBackgroundCoordinator

    init(
        services: PacketryServiceRegistry = .foundation,
        backgroundCoordinator: PacketryBackgroundCoordinator = PacketryBackgroundCoordinator(),
        snapshot: PacketryWindowSnapshot = .foundation
    ) {
        self.services = services
        self.backgroundCoordinator = backgroundCoordinator
        self.snapshot = snapshot
    }

    func beginLaunchChecks() {
        snapshot.accessState = .checking
        snapshot.sessionState.statusMessage = "Checking helper installation, permissions, and interface inventory."
    }

    func finishLaunchChecks(with accessState: CaptureAccessState) {
        snapshot.accessState = accessState

        if accessState.isCaptureReady && snapshot.sessionState.phase == .idle {
            snapshot.sessionState.phase = .ready
            snapshot.sessionState.statusMessage = "Live capture can be configured."
        }
    }

    func beginDocumentOpen(at fileURL: URL) {
        snapshot.documentState = CaptureDocumentState(
            phase: .opening,
            fileURL: fileURL,
            packetCount: 0,
            statusMessage: "Opening \(fileURL.lastPathComponent)..."
        )

        Task {
            await backgroundCoordinator.beginOperation("document-open")
        }
    }

    func finishDocumentOpen(packetCount: Int) {
        snapshot.documentState.phase = .loaded
        snapshot.documentState.packetCount = packetCount
        snapshot.documentState.statusMessage = "Loaded \(packetCount) packets."
        snapshot.visiblePacketCount = packetCount

        Task {
            await backgroundCoordinator.endOperation("document-open")
        }
    }

    func updateSession(
        phase: CaptureSessionState.Phase,
        interfaceID: String? = nil,
        capturedPacketCount: Int? = nil,
        statusMessage: String,
        lastError: PacketryCoreError? = nil
    ) {
        snapshot.sessionState.phase = phase
        snapshot.sessionState.selectedInterfaceID = interfaceID
        snapshot.sessionState.capturedPacketCount = capturedPacketCount ?? snapshot.sessionState.capturedPacketCount
        snapshot.sessionState.statusMessage = statusMessage
        snapshot.sessionState.lastError = lastError
    }

    func cancelBackgroundWork() {
        Task {
            await backgroundCoordinator.cancelAll()
        }

        snapshot.sessionState.statusMessage = "Cancelled pending background work."

        if snapshot.sessionState.phase != .idle {
            snapshot.sessionState.phase = .ready
        }
    }
}
