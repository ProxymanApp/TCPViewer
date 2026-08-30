//
//  TCPViewerCLICommandCoordinatorTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation
import Testing
@testable import TCPViewer

@Suite(.serialized)
@MainActor
struct TCPViewerCLICommandCoordinatorTests {
    @Test func startupScanProcessesRequestsWrittenBeforeTheObserver() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = fixture.request(.captureStatus)
        try fixture.store.writeRequest(request)

        fixture.coordinator.start()
        #expect(await fixture.notifications.waitForResponses(count: 1))

        let response = try fixture.store.readResponse(requestID: request.requestID)
        #expect(response.requestID == request.requestID)
        #expect(response.command == .captureStatus)
        #expect(response.data?["handled"] == .bool(true))
    }

    @Test func correlatesAndSerializesConcurrentInvocations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.coordinator.start()
        let requests = (0..<12).map { index in
            fixture.request(index.isMultiple(of: 2) ? .packetsList : .interfacesList)
        }
        for request in requests {
            try fixture.store.writeRequest(request)
            fixture.notifications.post(TCPViewerCLINotificationName.request)
        }

        #expect(await fixture.notifications.waitForResponses(count: requests.count))
        #expect(fixture.router.maximumConcurrentRouteCount == 1)
        #expect(Set(fixture.router.requestIDs) == Set(requests.map(\.requestID)))
        for request in requests {
            let response = try fixture.store.readResponse(requestID: request.requestID)
            #expect(response.requestID == request.requestID)
            #expect(response.command == request.command)
        }
    }

    private final class Fixture {
        let root: URL
        let store: TCPViewerCLIFileStore
        let notifications = FakeNotificationCenter()
        let router = FakeRouter()
        let coordinator: TCPViewerCLICommandCoordinator

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerCLICoordinatorTests-\(UUID().uuidString)")
            store = TCPViewerCLIFileStore(rootURL: root)
            try store.prepareDirectories()
            coordinator = TCPViewerCLICommandCoordinator(
                fileStore: store,
                notificationCenter: notifications,
                router: router
            )
        }

        func request(_ command: TCPViewerCLICommand) -> TCPViewerCLIRequest {
            TCPViewerCLIRequest(command: command, expiresAt: Date().addingTimeInterval(30))
        }

        func remove() {
            coordinator.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class FakeRouter: TCPViewerCLICommandRouting {
        private let lock = NSLock()
        private var concurrentRouteCount = 0
        private(set) var maximumConcurrentRouteCount = 0
        private(set) var requestIDs: [String] = []

        func route(_ request: TCPViewerCLIRequest, completion: @escaping (TCPViewerCLIResponse) -> Void) {
            lock.lock()
            concurrentRouteCount += 1
            maximumConcurrentRouteCount = max(maximumConcurrentRouteCount, concurrentRouteCount)
            requestIDs.append(request.requestID)
            lock.unlock()
            completion(.success(
                requestID: request.requestID,
                command: request.command,
                data: ["handled": .bool(true)]
            ))
            lock.lock()
            concurrentRouteCount -= 1
            lock.unlock()
        }
    }

    private final class FakeNotificationCenter: TCPViewerCLINotificationCentering {
        private let lock = NSLock()
        private var handlers: [String: () -> Void] = [:]
        private var responseCount = 0

        func post(_ name: String) {
            lock.lock()
            let handler = handlers[name]
            if name == TCPViewerCLINotificationName.response {
                responseCount += 1
            }
            lock.unlock()
            handler?()
        }

        func observe(_ name: String, handler: @escaping () -> Void) -> any TCPViewerCLINotificationObserving {
            lock.lock()
            handlers[name] = handler
            lock.unlock()
            return Token()
        }

        // Yield the main actor while the coordinator returns app routing work to it.
        func waitForResponses(count expectedCount: Int) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                lock.lock()
                let hasReceivedAllResponses = responseCount >= expectedCount
                lock.unlock()
                if hasReceivedAllResponses { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            lock.lock()
            let hasReceivedAllResponses = responseCount >= expectedCount
            lock.unlock()
            return hasReceivedAllResponses
        }

        private final class Token: TCPViewerCLINotificationObserving {}
    }
}
