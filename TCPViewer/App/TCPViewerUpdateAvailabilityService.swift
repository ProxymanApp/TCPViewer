//
//  TCPViewerUpdateAvailabilityService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 12/7/26.
//

import Foundation

final class TCPViewerUpdateAvailabilityService {
    private struct Response: Decodable {
        let newReleasesCount: Int

        private enum CodingKeys: String, CodingKey {
            case newReleasesCount = "new_releases_count"
        }
    }

    private let baseURLOverride: URL?
    private let bundleInfo: [String: Any]
    private let transport: any TCPViewerServerNetworkTransport
    private let buildNumberProvider: () -> String
    private let workerQueue: DispatchQueue
    private let decoder = JSONDecoder()

    init(
        baseURL: URL? = nil,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        transport: any TCPViewerServerNetworkTransport = TCPViewerServerURLSessionTransport(),
        buildNumberProvider: @escaping () -> String = { TCPViewerLicenseAppVersion.current.buildNumber },
        workerQueue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.UpdateAvailability", qos: .utility)
    ) {
        self.baseURLOverride = baseURL
        self.bundleInfo = bundleInfo
        self.transport = transport
        self.buildNumberProvider = buildNumberProvider
        self.workerQueue = workerQueue
    }

    // Fetch the number of releases newer than this build without invoking Sparkle's skipped-version policy.
    func checkForAvailableBuilds(completion: @escaping (Int) -> Void) {
        workerQueue.async { [weak self] in
            guard let self, let request = self.makeRequest() else {
                completion(0)
                return
            }

            self.transport.perform(request) { [weak self] data, response, error in
                guard let self else {
                    return
                }

                self.workerQueue.async {
                    completion(self.availableBuildCount(data: data, response: response, error: error))
                }
            }
        }
    }

    // Build the existing release-count request with the running app's numeric build identifier.
    private func makeRequest() -> URLRequest? {
        let baseURL = baseURLOverride ?? TCPViewerServerEndpoint.baseURL(bundleInfo: bundleInfo)
        let endpointURL = baseURL.appendingPathComponent("api/releases/check-new-updates")
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "platform", value: "macos"),
            URLQueryItem(name: "build_number", value: buildNumberProvider()),
        ]
        guard let url = components.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        return request
    }

    // Treat all network and malformed responses as no badge so update checks never disrupt launch.
    private func availableBuildCount(
        data: Data?,
        response: HTTPURLResponse?,
        error: Error?
    ) -> Int {
        guard error == nil,
              response?.statusCode == 200,
              let data,
              let result = try? decoder.decode(Response.self, from: data) else {
            return 0
        }

        return max(0, result.newReleasesCount)
    }
}
