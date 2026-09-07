//
//  TCPViewerLicenseSecrets.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/7/26.
//

import Foundation
import Security

protocol TCPViewerLicenseSecretStoring {
    func read(_ account: String) -> Data?
    func write(_ data: Data, account: String) throws
    func remove(_ account: String)
}

final class TCPViewerLicenseKeychain: TCPViewerLicenseSecretStoring {
    private let service: String

    init(service: String = "com.proxyman.TCPViewer.license.v1") { self.service = service }

    func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data, account: String) throws {
        let query = query(account)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}

struct TCPViewerLicenseClockState: Codable {
    var maximumTime: TimeInterval
    var requiresVerification: Bool
}
