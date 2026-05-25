//
//  TCPViewerLicenseNetworkClient.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation

protocol TCPViewerLicenseNetworkClienting: AnyObject {
    func registerLicense(
        licenseKey: String,
        deviceName: String,
        deviceUUID: String,
        buildNumber: String,
        appVersion: String,
        osVersion: String,
        completion: @escaping (Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void
    )

    func verifyLicense(
        license: TCPViewerLicense,
        deviceUUID: String,
        buildNumber: String,
        appVersion: String,
        osVersion: String,
        completion: @escaping (Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void
    )

    func revokeLicense(
        license: TCPViewerLicense,
        completion: @escaping (Result<Void, TCPViewerLicenseError>) -> Void
    )
}

protocol TCPViewerLicenseNetworkTransport {
    func perform(
        _ request: URLRequest,
        completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void
    )
}

final class TCPViewerLicenseURLSessionTransport: TCPViewerLicenseNetworkTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func perform(
        _ request: URLRequest,
        completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void
    ) {
        let task = session.dataTask(with: request) { data, response, error in
            completion(data, response as? HTTPURLResponse, error)
        }
        task.resume()
    }
}

final class TCPViewerLicenseNetworkClient: TCPViewerLicenseNetworkClienting {
    private enum ServerEndpoint {
        static let localServerInfoKey = "TCPViewerUsesLocalLicenseServer"
        static let productionBaseURL = URL(string: "https://api-tcpviewer.proxyman.com")!
        static let localBaseURL = URL(string: "http://proxyman.debug:3000")!
    }

    private let baseURLOverride: URL?
    private let bundleInfo: [String: Any]
    private let transport: any TCPViewerLicenseNetworkTransport
    private let decoder = JSONDecoder()

    init(
        baseURL: URL? = nil,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        transport: any TCPViewerLicenseNetworkTransport = TCPViewerLicenseURLSessionTransport()
    ) {
        self.baseURLOverride = baseURL
        self.bundleInfo = bundleInfo
        self.transport = transport
    }

    func registerLicense(
        licenseKey: String,
        deviceName: String,
        deviceUUID: String,
        buildNumber: String,
        appVersion: String,
        osVersion: String,
        completion: @escaping (Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void
    ) {
        let body: [String: Any] = [
            "deviceName": deviceName,
            "deviceUuid": deviceUUID,
            "licenseKey": licenseKey,
            "platform": "macos",
            "buildNumber": buildNumber,
            "appVersion": appVersion,
            "osVersion": osVersion,
        ]
        sendJSONRequest(
            path: "/api/devices/register",
            method: "POST",
            body: body,
            completion: completion
        )
    }

    func verifyLicense(
        license: TCPViewerLicense,
        deviceUUID: String,
        buildNumber: String,
        appVersion: String,
        osVersion: String,
        completion: @escaping (Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void
    ) {
        let body: [String: Any] = [
            "buildNumber": buildNumber,
            "signature": license.signature,
            "platform": "macos",
            "deviceUuid": deviceUUID,
            "appVersion": appVersion,
            "osVersion": osVersion,
        ]
        sendJSONRequest(
            path: "/api/devices/verify",
            method: "POST",
            body: body,
            completion: completion
        )
    }

    func revokeLicense(
        license: TCPViewerLicense,
        completion: @escaping (Result<Void, TCPViewerLicenseError>) -> Void
    ) {
        let body: [String: Any] = [
            "signature": license.signature,
        ]
        sendJSONRequest(
            path: "/api/devices/revoke",
            method: "DELETE",
            body: body
        ) { (result: Result<TCPViewerLicenseEmptyResponse, TCPViewerLicenseError>) in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func sendJSONRequest<Response: Decodable>(
        path: String,
        method: String,
        body: [String: Any],
        completion: @escaping (Result<Response, TCPViewerLicenseError>) -> Void
    ) {
        do {
            let request = try makeJSONRequest(path: path, method: method, body: body)
            transport.perform(request) { [decoder] data, response, error in
                if let error {
                    completion(.failure(Self.mapNetworkError(error)))
                    return
                }

                guard let response else {
                    completion(.failure(.error("Missing server response.")))
                    return
                }

                switch response.statusCode {
                case 200:
                    if Response.self == TCPViewerLicenseEmptyResponse.self {
                        completion(.success(TCPViewerLicenseEmptyResponse() as! Response))
                        return
                    }

                    guard let data else {
                        completion(.failure(.error("Could not parse license response.")))
                        return
                    }

                    do {
                        completion(.success(try decoder.decode(Response.self, from: data)))
                    } catch {
                        completion(.failure(.error(error.localizedDescription)))
                    }
                default:
                    completion(.failure(Self.mapServerError(from: data)))
                }
            }
        } catch {
            completion(.failure(.error(error.localizedDescription)))
        }
    }

    private func makeJSONRequest(path: String, method: String, body: [String: Any]) throws -> URLRequest {
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let baseURL = baseURLOverride ?? Self.baseURL(bundleInfo: bundleInfo)
        guard let url = URL(string: relativePath, relativeTo: baseURL)?.absoluteURL else {
            throw TCPViewerLicenseError.error("Invalid license server URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    // Resolve the shared server root so every license request honors the same build setting.
    private static func baseURL(bundleInfo: [String: Any]) -> URL {
        guard isEnabled(bundleInfo[ServerEndpoint.localServerInfoKey]) else {
            return ServerEndpoint.productionBaseURL
        }

        return ServerEndpoint.localBaseURL
    }

    // Accept plist/build-setting values regardless of whether Xcode emits string, number, or bool.
    private static func isEnabled(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }

        if let value = value as? NSNumber {
            return value.boolValue
        }

        guard let value = value as? String else {
            return false
        }

        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "true", "yes", "on"].contains(normalizedValue)
    }

    private static func mapNetworkError(_ error: Error) -> TCPViewerLicenseError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .error(error.localizedDescription)
        }

        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorNetworkConnectionLost:
            return .noInternetConnection
        default:
            return .error(error.localizedDescription)
        }
    }

    private static func mapServerError(from data: Data?) -> TCPViewerLicenseError {
        guard let message = serverErrorMessage(from: data) else {
            return .error("Unknown license server error.")
        }

        let lowercased = message.lowercased()
        if lowercased.contains("seat limit") {
            return .outOfSeats
        }
        if lowercased.contains("expired for this release") {
            return .renewalRequired
        }
        if lowercased.contains("expired") {
            return .expired
        }
        if lowercased.contains("not found") ||
            lowercased.contains("disabled") ||
            lowercased.contains("invalid") ||
            lowercased.contains("not active") ||
            lowercased.contains("signature") ||
            lowercased.contains("device uuid") {
            return .invalidLicense
        }

        return .error(message)
    }

    private static func serverErrorMessage(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json["error"] as? String ?? json["message"] as? String
    }
}

private struct TCPViewerLicenseEmptyResponse: Decodable {}
