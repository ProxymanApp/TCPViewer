//
//  TCPViewerLicenseStorage.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import CryptoKit
import Foundation

protocol TCPViewerLicenseStoring {
    func readLicense() -> TCPViewerLicense?
    func writeLicense(_ license: TCPViewerLicense) throws
    func removeLicense()
}

final class TCPViewerLicenseStorage: TCPViewerLicenseStoring {
    private static let defaultFileName = "receipt.bin"

    private let fileURL: URL
    private let fileManager: FileManager
    private let cipher: TCPViewerLicenseCipher
    private let lock = NSLock()

    init(
        fileURL: URL = TCPViewerUserDataDirectory.shared.settingsFileURL(named: TCPViewerLicenseStorage.defaultFileName),
        fileManager: FileManager = .default,
        cipher: TCPViewerLicenseCipher = TCPViewerLicenseCipher()
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.cipher = cipher
    }

    func readLicense() -> TCPViewerLicense? {
        lock.withLock {
            guard let encryptedData = try? Data(contentsOf: fileURL) else {
                return nil
            }

            do {
                let data = try cipher.decrypt(encryptedData)
                return try JSONDecoder().decode(TCPViewerLicense.self, from: data)
            } catch {
                return nil
            }
        }
    }

    func writeLicense(_ license: TCPViewerLicense) throws {
        try lock.withLock {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(license)
            let encryptedData = try cipher.encrypt(data)
            try encryptedData.write(to: fileURL, options: .atomic)
        }
    }

    func removeLicense() {
        lock.withLock {
            try? fileManager.removeItem(at: fileURL)
        }
    }
}

struct TCPViewerLicenseCipher {
    enum CipherError: Error {
        case missingEncryptedPayload
    }

    private let key: SymmetricKey

    init(secret: String = TCPViewerLicenseCipher.defaultSecret()) {
        let digest = SHA256.hash(data: Data(secret.utf8))
        self.key = SymmetricKey(data: Data(digest))
    }

    func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw CipherError.missingEncryptedPayload
        }

        return combined
    }

    func decrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }

    private static func defaultSecret() -> String {
        let candidateKeys = ["TCPViewerBuildKey", "TCPVIEWER_BUILD_KEY"]
        for key in candidateKeys {
            if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !value.hasPrefix("$(") {
                return value
            }
        }

        return "TCPViewerLicenseStorageKey.v1.Proxyman"
    }
}

private extension NSLock {
    func withLock<Value>(_ closure: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try closure()
    }
}
