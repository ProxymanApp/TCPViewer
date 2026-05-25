//
//  TCPViewerLicenseNetworkClientTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerLicenseNetworkClientTests {
    @Test func defaultClientUsesProductionEndpoint() throws {
        let transport = StubLicenseTransport()
        transport.nextResult = .success((makeLicenseData(), makeResponse(statusCode: 200)))
        let client = TCPViewerLicenseNetworkClient(transport: transport)

        _ = waitForLicenseResult {
            client.registerLicense(
                licenseKey: "TCPV-KEY",
                deviceName: "Ada's Mac",
                deviceUUID: "device-1",
                buildNumber: "123",
                appVersion: "1.2.3",
                osVersion: "macOS 15.6",
                completion: $0
            )
        }

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api-tcpviewer.proxyman.com/api/devices/register")
    }

    @Test func localServerToggleRoutesEveryLicenseRequestToLocalhost() throws {
        let transport = StubLicenseTransport()
        let client = TCPViewerLicenseNetworkClient(usesLocalServer: true, transport: transport)

        transport.nextResult = .success((makeLicenseData(), makeResponse(statusCode: 200)))
        _ = waitForLicenseResult {
            client.registerLicense(
                licenseKey: "TCPV-KEY",
                deviceName: "Ada's Mac",
                deviceUUID: "device-1",
                buildNumber: "123",
                appVersion: "1.2.3",
                osVersion: "macOS 15.6",
                completion: $0
            )
        }

        transport.nextResult = .success((makeLicenseData(), makeResponse(statusCode: 200)))
        _ = waitForLicenseResult {
            client.verifyLicense(
                license: makeLicense(),
                deviceUUID: "device-1",
                buildNumber: "456",
                appVersion: "1.2.3",
                osVersion: "macOS 15.6",
                completion: $0
            )
        }

        transport.nextResult = .success((Data("{}".utf8), makeResponse(statusCode: 200)))
        _ = waitForVoidResult {
            client.revokeLicense(license: makeLicense(), completion: $0)
        }

        #expect(transport.requests.map { $0.url?.absoluteString } == [
            "http://localhost:3000/api/devices/register",
            "http://localhost:3000/api/devices/verify",
            "http://localhost:3000/api/devices/revoke",
        ])
    }

    @Test func registerLicenseBuildsExpectedRequestPayload() throws {
        let transport = StubLicenseTransport()
        transport.nextResult = .success((makeLicenseData(), makeResponse(statusCode: 200)))
        let client = TCPViewerLicenseNetworkClient(baseURL: URL(string: "https://example.com")!, transport: transport)

        let result = waitForLicenseResult {
            client.registerLicense(
                licenseKey: "TCPV-KEY",
                deviceName: "Ada's Mac",
                deviceUUID: "device-1",
                buildNumber: "123",
                appVersion: "1.2.3",
                osVersion: "macOS 15.6",
                completion: $0
            )
        }

        #expect(try result.get().email == "ada@example.com")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/devices/register")

        let body = try requestBody(from: request)
        #expect(body["licenseKey"] as? String == "TCPV-KEY")
        #expect(body["deviceName"] as? String == "Ada's Mac")
        #expect(body["deviceUuid"] as? String == "device-1")
        #expect(body["platform"] as? String == "macos")
        #expect(body["buildNumber"] as? String == "123")
        #expect(body["appVersion"] as? String == "1.2.3")
        #expect(body["osVersion"] as? String == "macOS 15.6")
    }

    @Test func verifyLicenseBuildsExpectedRequestPayload() throws {
        let transport = StubLicenseTransport()
        transport.nextResult = .success((makeLicenseData(), makeResponse(statusCode: 200)))
        let client = TCPViewerLicenseNetworkClient(baseURL: URL(string: "https://example.com")!, transport: transport)

        _ = waitForLicenseResult {
            client.verifyLicense(
                license: makeLicense(),
                deviceUUID: "device-1",
                buildNumber: "456",
                appVersion: "1.2.3",
                osVersion: "macOS 15.6",
                completion: $0
            )
        }

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/devices/verify")

        let body = try requestBody(from: request)
        #expect(body["signature"] as? String == makeLicense().signature)
        #expect(body["deviceUuid"] as? String == "device-1")
        #expect(body["platform"] as? String == "macos")
        #expect(body["buildNumber"] as? String == "456")
        #expect(body["appVersion"] as? String == "1.2.3")
        #expect(body["osVersion"] as? String == "macOS 15.6")
    }

    @Test func revokeLicenseBuildsExpectedRequestPayload() throws {
        let transport = StubLicenseTransport()
        transport.nextResult = .success((Data("{}".utf8), makeResponse(statusCode: 200)))
        let client = TCPViewerLicenseNetworkClient(baseURL: URL(string: "https://example.com")!, transport: transport)

        let result = waitForVoidResult {
            client.revokeLicense(license: makeLicense(), completion: $0)
        }

        #expect(try result.get() == ())
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/devices/revoke")
        let body = try requestBody(from: request)
        #expect(body["signature"] as? String == makeLicense().signature)
    }

    @Test func mapsSeatLimitAndNetworkErrors() {
        let seatTransport = StubLicenseTransport()
        seatTransport.nextResult = .success((
            Data(#"{"error":"License seat limit reached. Cannot register more devices."}"#.utf8),
            makeResponse(statusCode: 400)
        ))
        let seatClient = TCPViewerLicenseNetworkClient(baseURL: URL(string: "https://example.com")!, transport: seatTransport)

        let seatResult = waitForLicenseResult {
            seatClient.registerLicense(
                licenseKey: "TCPV-KEY",
                deviceName: "Ada's Mac",
                deviceUUID: "device-1",
                buildNumber: "123",
                appVersion: "1.2.3",
                osVersion: "macOS 15.6",
                completion: $0
            )
        }

        #expect(seatResult == .failure(.outOfSeats))

        let offlineTransport = StubLicenseTransport()
        offlineTransport.nextResult = .failure(URLError(.notConnectedToInternet))
        let offlineClient = TCPViewerLicenseNetworkClient(baseURL: URL(string: "https://example.com")!, transport: offlineTransport)

        let offlineResult = waitForLicenseResult {
            offlineClient.verifyLicense(
                license: makeLicense(),
                deviceUUID: "device-1",
                buildNumber: "123",
                appVersion: "1.2.3",
                osVersion: "macOS 15.6",
                completion: $0
            )
        }

        #expect(offlineResult == .failure(.noInternetConnection))
    }

    @Test func mapsBackendLicenseErrors() {
        let cases: [(message: String, expectedError: TCPViewerLicenseError)] = [
            ("License key has expired for this release version.", .renewalRequired),
            ("License has expired.", .expired),
            ("License is disabled.", .invalidLicense),
            ("Device is not active.", .invalidLicense),
            ("Device not found.", .invalidLicense),
        ]

        for testCase in cases {
            let transport = StubLicenseTransport()
            transport.nextResult = .success((
                Data(#"{"error":"\#(testCase.message)"}"#.utf8),
                makeResponse(statusCode: 400)
            ))
            let client = TCPViewerLicenseNetworkClient(baseURL: URL(string: "https://example.com")!, transport: transport)

            let result = waitForLicenseResult {
                client.verifyLicense(
                    license: makeLicense(),
                    deviceUUID: "device-1",
                    buildNumber: "123",
                    appVersion: "1.2.3",
                    osVersion: "macOS 15.6",
                    completion: $0
                )
            }

            #expect(result == .failure(testCase.expectedError))
        }
    }

    private func makeLicense() -> TCPViewerLicense {
        TCPViewerLicense(
            signature: "abcdefghijklmnopqrstuvwxyz",
            deviceUUID: "device-1",
            email: "ada@example.com",
            purchaseAt: "2026-05-01T10:20:30.123Z",
            expiryDate: "2027-05-01T10:20:30.123Z"
        )
    }

    private func makeLicenseData() -> Data {
        """
        {
          "signature": "abcdefghijklmnopqrstuvwxyz",
          "device_uuid": "device-1",
          "email": "ada@example.com",
          "purchaseAt": "2026-05-01T10:20:30.123Z",
          "expiryAt": "2027-05-01T10:20:30.123Z",
          "licenseType": "standard_license"
        }
        """.data(using: .utf8)!
    }

    private func makeResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func requestBody(from request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitForLicenseResult(
        _ start: (@escaping (Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void) -> Void
    ) -> Result<TCPViewerLicense, TCPViewerLicenseError> {
        var result: Result<TCPViewerLicense, TCPViewerLicenseError>?
        let semaphore = DispatchSemaphore(value: 0)
        start {
            result = $0
            semaphore.signal()
        }
        #expect(semaphore.wait(timeout: .now() + 2) == .success)
        return result ?? .failure(.error("Missing callback"))
    }

    private func waitForVoidResult(
        _ start: (@escaping (Result<Void, TCPViewerLicenseError>) -> Void) -> Void
    ) -> Result<Void, TCPViewerLicenseError> {
        var result: Result<Void, TCPViewerLicenseError>?
        let semaphore = DispatchSemaphore(value: 0)
        start {
            result = $0
            semaphore.signal()
        }
        #expect(semaphore.wait(timeout: .now() + 2) == .success)
        return result ?? .failure(.error("Missing callback"))
    }
}

private final class StubLicenseTransport: TCPViewerLicenseNetworkTransport {
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
