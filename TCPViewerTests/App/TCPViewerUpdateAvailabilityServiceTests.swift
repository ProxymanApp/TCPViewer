//
//  TCPViewerUpdateAvailabilityServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 12/7/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerUpdateAvailabilityServiceTests {
    @Test func fetchesNewerBuildCountFromReleaseEndpoint() throws {
        let transport = StubUpdateAvailabilityTransport()
        transport.nextResult = .success((
            Data(#"{"new_releases_count":2}"#.utf8),
            makeResponse(statusCode: 200)
        ))
        let service = TCPViewerUpdateAvailabilityService(
            baseURL: URL(string: "https://example.com")!,
            transport: transport,
            buildNumberProvider: { "123" },
            workerQueue: DispatchQueue(label: "TCPViewerTests.UpdateAvailability", qos: .userInitiated)
        )

        let count = waitForCount { service.checkForAvailableBuilds(completion: $0) }

        #expect(count == 2)
        let request = try #require(transport.requests.first)
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        #expect(request.httpMethod == "GET")
        #expect(components.path == "/api/releases/check-new-updates")
        #expect(components.queryItems?.contains(URLQueryItem(name: "platform", value: "macos")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "build_number", value: "123")) == true)
    }

    @Test func hidesBadgeForReleaseEndpointFailures() {
        let transport = StubUpdateAvailabilityTransport()
        transport.nextResult = .success((Data(), makeResponse(statusCode: 404)))
        let service = TCPViewerUpdateAvailabilityService(
            baseURL: URL(string: "https://example.com")!,
            transport: transport,
            workerQueue: DispatchQueue(label: "TCPViewerTests.UpdateAvailability", qos: .userInitiated)
        )

        let count = waitForCount { service.checkForAvailableBuilds(completion: $0) }

        #expect(count == 0)
    }

    @Test func usesLocalServerWhenConfigured() throws {
        let transport = StubUpdateAvailabilityTransport()
        transport.nextResult = .success((
            Data(#"{"new_releases_count":1}"#.utf8),
            makeResponse(statusCode: 200)
        ))
        let service = TCPViewerUpdateAvailabilityService(
            bundleInfo: ["TCPViewerUsesLocalLicenseServer": true],
            transport: transport,
            buildNumberProvider: { "123" },
            workerQueue: DispatchQueue(label: "TCPViewerTests.UpdateAvailability", qos: .userInitiated)
        )

        _ = waitForCount { service.checkForAvailableBuilds(completion: $0) }

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://proxyman.debug:3000/api/releases/check-new-updates?platform=macos&build_number=123")
    }

    private func makeResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func waitForCount(_ start: (@escaping (Int) -> Void) -> Void) -> Int {
        var count: Int?
        let semaphore = DispatchSemaphore(value: 0)
        start {
            count = $0
            semaphore.signal()
        }
        #expect(semaphore.wait(timeout: .now() + 2) == .success)
        return count ?? 0
    }
}

private final class StubUpdateAvailabilityTransport: TCPViewerServerNetworkTransport {
    enum TransportResult {
        case success((Data?, HTTPURLResponse))
        case failure(Error)
    }

    var requests: [URLRequest] = []
    var nextResult: TransportResult = .success((
        Data(),
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    ))

    func perform(
        _ request: URLRequest,
        completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void
    ) {
        requests.append(request)
        switch nextResult {
        case .success(let response):
            completion(response.0, response.1, nil)
        case .failure(let error):
            completion(nil, nil, error)
        }
    }
}
