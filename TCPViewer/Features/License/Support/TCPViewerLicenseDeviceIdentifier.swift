//
//  TCPViewerLicenseDeviceIdentifier.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import CryptoKit
import Foundation
import IOKit
import SystemConfiguration

protocol TCPViewerLicenseDeviceProviding {
    func deviceName() -> String
    func hashedDeviceIDs() -> [String]
}

extension TCPViewerLicenseDeviceProviding {
    func currentDeviceUUID() -> String? {
        hashedDeviceIDs().first
    }

    func isSameDeviceUUID(_ deviceUUID: String) -> Bool {
        hashedDeviceIDs().contains(deviceUUID)
    }
}

struct TCPViewerLicenseDeviceIdentifier: TCPViewerLicenseDeviceProviding {
    func deviceName() -> String {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String? else {
            return "Unknown device"
        }

        return name
    }

    func hashedDeviceIDs() -> [String] {
        rawDeviceIDs().map { rawID in
            let digest = SHA256.hash(data: Data(rawID.utf8))
            return Data(digest).base64EncodedString()
        }
    }

    private func rawDeviceIDs() -> [String] {
        let en0MAC = macAddress(forBSDName: "en0")
        let primaryMAC = primaryMACAddress()
        let serial = macSerialNumber() ?? ""

        // Keep several stable candidates so existing receipts survive interface changes.
        return [
            en0MAC + serial,
            serial,
            primaryMAC + serial,
            en0MAC,
            primaryMAC,
        ].filter { !$0.isEmpty }
    }

    private func macSerialNumber() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        let serial = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformSerialNumberKey as CFString,
            kCFAllocatorDefault,
            0
        )
        return serial?.takeUnretainedValue() as? String
    }

    private func macAddress(forBSDName bsdName: String) -> String {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            return ""
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return ""
        }
        defer { IOObjectRelease(iterator) }

        return macAddress(fromIterator: iterator)
    }

    private func primaryMACAddress() -> String {
        guard let matching = IOServiceMatching("IOEthernetInterface") as NSMutableDictionary? else {
            return ""
        }

        matching["IOPropertyMatch"] = ["IOPrimaryInterface": true]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return ""
        }
        defer { IOObjectRelease(iterator) }

        return macAddress(fromIterator: iterator)
    }

    private func macAddress(fromIterator iterator: io_iterator_t) -> String {
        var interface = IOIteratorNext(iterator)
        while interface != 0 {
            let currentInterface = interface
            interface = IOIteratorNext(iterator)
            defer { IOObjectRelease(currentInterface) }

            var controller: io_object_t = 0
            guard IORegistryEntryGetParentEntry(currentInterface, "IOService", &controller) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(controller) }

            let data = IORegistryEntryCreateCFProperty(
                controller,
                "IOMACAddress" as CFString,
                kCFAllocatorDefault,
                0
            )
            guard let macData = data?.takeRetainedValue() as? Data else {
                continue
            }

            return macData.map { String(format: "%02x", $0) }.joined(separator: ":")
        }

        return ""
    }
}
