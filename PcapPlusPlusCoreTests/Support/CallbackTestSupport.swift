//
//  CallbackTestSupport.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Foundation
@testable import PcapPlusPlusCore

extension CaptureInterfaceProviding {
    func listInterfaces() async throws -> [CaptureInterfaceSummary] {
        try await waitForResult { completion in
            listInterfaces(completion: completion)
        }
    }
}

extension CaptureFilterValidating {
    func validateCaptureFilter(_ expression: String) async -> CaptureFilterValidation {
        await withCheckedContinuation { continuation in
            validateCaptureFilter(expression) { validation in
                continuation.resume(returning: validation)
            }
        }
    }
}

extension LiveCaptureProviding {
    func makeLiveCaptureSession(
        interfaceID: String,
        options: CaptureOptions
    ) async throws -> any LiveCaptureSessionProviding {
        try await waitForResult { completion in
            makeLiveCaptureSession(interfaceID: interfaceID, options: options, completion: completion)
        }
    }
}

extension OfflineCaptureProviding {
    func openOfflineCaptureDocument(at fileURL: URL) async throws -> any OfflineCaptureDocumentProviding {
        try await waitForResult { completion in
            openOfflineCaptureDocument(at: fileURL, completion: completion)
        }
    }

    func loadPacketSummaries(from fileURL: URL) async throws -> [PacketSummary] {
        try await waitForResult { completion in
            loadPacketSummaries(from: fileURL, completion: completion)
        }
    }
}

extension LiveCaptureSessionProviding {
    func events() -> AsyncThrowingStream<PacketIngestEvent, Error> {
        AsyncThrowingStream { continuation in
            eventHandler = { result in
                switch result {
                case .success(let event):
                    continuation.yield(event)
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func start() async throws {
        try await waitForResult { completion in
            start(completion: completion)
        }
    }

    func pause() async throws {
        try await waitForResult { completion in
            pause(completion: completion)
        }
    }

    func resume() async throws {
        try await waitForResult { completion in
            resume(completion: completion)
        }
    }

    func stop() async throws {
        try await waitForResult { completion in
            stop(completion: completion)
        }
    }

    func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection {
        try await waitForResult { completion in
            inspectPacket(id: id, completion: completion)
        }
    }

    func exportPackets(withIDs identifiers: [PacketSummary.ID], to url: URL, format: CaptureFileFormat) async throws {
        try await waitForResult { completion in
            exportPackets(withIDs: identifiers, to: url, format: format, completion: completion)
        }
    }

    func healthSnapshot() async -> CaptureHealthSnapshot {
        await withCheckedContinuation { continuation in
            healthSnapshot { health in
                continuation.resume(returning: health)
            }
        }
    }
}

extension OfflineCaptureDocumentProviding {
    func events() -> AsyncThrowingStream<PacketIngestEvent, Error> {
        AsyncThrowingStream { continuation in
            eventHandler = { result in
                switch result {
                case .success(let event):
                    continuation.yield(event)
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func open() async throws -> [PacketSummary] {
        try await waitForResult { completion in
            open(completion: completion)
        }
    }

    func reopen() async throws -> [PacketSummary] {
        try await waitForResult { completion in
            reopen(completion: completion)
        }
    }

    func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection {
        try await waitForResult { completion in
            inspectPacket(id: id, completion: completion)
        }
    }

    func save() async throws {
        try await waitForResult { completion in
            save(completion: completion)
        }
    }

    func save(to url: URL, format: CaptureFileFormat) async throws {
        try await waitForResult { completion in
            save(to: url, format: format, completion: completion)
        }
    }

    func exportPackets(withIDs identifiers: [PacketSummary.ID], to url: URL, format: CaptureFileFormat) async throws {
        try await waitForResult { completion in
            exportPackets(withIDs: identifiers, to: url, format: format, completion: completion)
        }
    }

    func cancelLoading() async {
        await withCheckedContinuation { continuation in
            cancelLoading {
                continuation.resume()
            }
        }
    }
}

private func waitForResult<Value>(
    _ start: (@escaping TCPViewerCompletion<Value>) -> Void
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        start { result in
            continuation.resume(with: result)
        }
    }
}

private func waitForResult(
    _ start: (@escaping TCPViewerVoidCompletion) -> Void
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        start { result in
            continuation.resume(with: result)
        }
    }
}
