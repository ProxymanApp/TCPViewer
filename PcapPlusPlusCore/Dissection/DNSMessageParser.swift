//
//  DNSMessageParser.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/8/26.
//

import Darwin
import Foundation

struct DNSMessageParser {
    private static let maximumRecordCount = 64
    private static let maximumResolutionCount = 32
    private static let maximumNameJumps = 8
    private static let maximumCNAMEHops = 8

    private struct Question {
        let name: String
        let type: UInt16
        let recordClass: UInt16
    }

    private struct AddressRecord {
        let ownerName: String
        let address: String
        let timeToLive: UInt32
    }

    private struct CNAMERecord {
        let targetName: String
        let timeToLive: UInt32
    }

    private enum RecordData {
        case address(String)
        case cname(String)
        case unsupported
    }

    private struct ResourceRecord {
        let ownerName: String
        let type: UInt16
        let recordClass: UInt16
        let timeToLive: UInt32
        let data: RecordData
    }

    private struct ResolvedAddress {
        let ownerName: String
        let address: String
        let timeToLive: UInt32
    }

    private let bytes: [UInt8]

    init(data: Data) {
        self.bytes = Array(data)
    }

    // Parse one complete DNS response into bounded hostname-to-address observations.
    func resolutions() -> [DNSResolutionObservation] {
        guard bytes.count >= 12,
              let flags = readUInt16(at: 2),
              flags & 0x8000 != 0,
              flags & 0x0200 == 0,
              flags & 0x000f == 0,
              let questionCount = readUInt16(at: 4),
              let answerCount = readUInt16(at: 6),
              let authorityCount = readUInt16(at: 8),
              let additionalCount = readUInt16(at: 10) else {
            return []
        }

        let totalRecordCount = Int(answerCount) + Int(authorityCount) + Int(additionalCount)
        guard Int(questionCount) <= Self.maximumRecordCount,
              totalRecordCount <= Self.maximumRecordCount else {
            return []
        }

        var cursor = 12
        var questions: [Question] = []
        questions.reserveCapacity(Int(questionCount))
        for _ in 0..<questionCount {
            guard let name = readName(cursor: &cursor),
                  let type = readUInt16(at: cursor),
                  let recordClass = readUInt16(at: cursor + 2) else {
                return []
            }
            cursor += 4
            questions.append(Question(name: name, type: type, recordClass: recordClass & 0x7fff))
        }

        var records: [ResourceRecord] = []
        records.reserveCapacity(totalRecordCount)
        for _ in 0..<totalRecordCount {
            guard let record = readResourceRecord(cursor: &cursor) else {
                return []
            }
            records.append(record)
        }

        return buildResolutions(questions: questions, records: records)
    }

    private func readResourceRecord(cursor: inout Int) -> ResourceRecord? {
        guard let ownerName = readName(cursor: &cursor),
              let type = readUInt16(at: cursor),
              let recordClass = readUInt16(at: cursor + 2),
              let timeToLive = readUInt32(at: cursor + 4),
              let dataLength = readUInt16(at: cursor + 8) else {
            return nil
        }
        cursor += 10
        let dataStart = cursor
        let dataEnd = dataStart + Int(dataLength)
        guard dataEnd >= dataStart, dataEnd <= bytes.count else {
            return nil
        }

        let data: RecordData
        switch type {
        case 1 where dataLength == 4:
            data = .address(ipv4Address(at: dataStart) ?? "")
        case 28 where dataLength == 16:
            data = .address(ipv6Address(at: dataStart) ?? "")
        case 5:
            var nameCursor = dataStart
            if let name = readName(cursor: &nameCursor), nameCursor <= dataEnd {
                data = .cname(name)
            } else {
                return nil
            }
        default:
            data = .unsupported
        }
        cursor = dataEnd

        if case .address(let address) = data, address.isEmpty {
            return nil
        }
        return ResourceRecord(
            ownerName: ownerName,
            type: type,
            recordClass: recordClass & 0x7fff,
            timeToLive: timeToLive,
            data: data
        )
    }

    private func buildResolutions(questions: [Question], records: [ResourceRecord]) -> [DNSResolutionObservation] {
        var addressesByOwner: [String: [AddressRecord]] = [:]
        var cnameByOwner: [String: CNAMERecord] = [:]

        for record in records where record.recordClass == 1 {
            switch record.data {
            case .address(let address) where record.type == 1 || record.type == 28:
                addressesByOwner[record.ownerName, default: []].append(AddressRecord(
                    ownerName: record.ownerName,
                    address: address,
                    timeToLive: record.timeToLive
                ))
            case .cname(let targetName):
                cnameByOwner[record.ownerName] = CNAMERecord(
                    targetName: targetName,
                    timeToLive: record.timeToLive
                )
            default:
                continue
            }
        }

        var output: [DNSResolutionObservation] = []
        var emittedKeys: Set<String> = []
        var usedAddressKeys: Set<String> = []

        for question in questions where question.recordClass == 1 && (question.type == 1 || question.type == 28) {
            let resolved = resolve(
                name: question.name,
                inheritedTTL: UInt32.max,
                addressesByOwner: addressesByOwner,
                cnameByOwner: cnameByOwner,
                visited: []
            )
            for address in resolved {
                let emittedKey = "\(question.name)|\(address.address)"
                guard emittedKeys.insert(emittedKey).inserted else { continue }
                output.append(DNSResolutionObservation(
                    domainName: question.name,
                    ipAddress: address.address,
                    timeToLive: address.timeToLive
                ))
                usedAddressKeys.insert("\(address.ownerName)|\(address.address)")
                if output.count == Self.maximumResolutionCount {
                    return output
                }
            }
        }

        // Responses normally repeat the question. Retain useful owner names when they do not.
        for record in records where record.recordClass == 1 {
            guard case .address(let address) = record.data else { continue }
            let addressKey = "\(record.ownerName)|\(address)"
            guard !usedAddressKeys.contains(addressKey),
                  emittedKeys.insert(addressKey).inserted else { continue }
            output.append(DNSResolutionObservation(
                domainName: record.ownerName,
                ipAddress: address,
                timeToLive: record.timeToLive
            ))
            if output.count == Self.maximumResolutionCount {
                return output
            }
        }
        return output
    }

    private func resolve(
        name: String,
        inheritedTTL: UInt32,
        addressesByOwner: [String: [AddressRecord]],
        cnameByOwner: [String: CNAMERecord],
        visited: Set<String>
    ) -> [ResolvedAddress] {
        guard visited.count < Self.maximumCNAMEHops, !visited.contains(name) else {
            return []
        }

        if let addresses = addressesByOwner[name], !addresses.isEmpty {
            return addresses.map {
                ResolvedAddress(
                    ownerName: $0.ownerName,
                    address: $0.address,
                    timeToLive: min(inheritedTTL, $0.timeToLive)
                )
            }
        }

        guard let cname = cnameByOwner[name] else {
            return []
        }
        var nextVisited = visited
        nextVisited.insert(name)
        return resolve(
            name: cname.targetName,
            inheritedTTL: min(inheritedTTL, cname.timeToLive),
            addressesByOwner: addressesByOwner,
            cnameByOwner: cnameByOwner,
            visited: nextVisited
        )
    }

    private func readName(cursor: inout Int) -> String? {
        let originalCursor = cursor
        var readCursor = cursor
        var nextCursor: Int?
        var labels: [String] = []
        var visitedPointers: Set<Int> = []
        var jumpCount = 0
        var renderedLength = 0

        // Pointer and length limits prevent malformed captures from looping or expanding forever.
        while readCursor < bytes.count {
            let length = bytes[readCursor]
            if length == 0 {
                cursor = nextCursor ?? (readCursor + 1)
                return normalizedName(labels.joined(separator: "."))
            }

            if length & 0xc0 == 0xc0 {
                guard readCursor + 1 < bytes.count, jumpCount < Self.maximumNameJumps else {
                    return nil
                }
                let pointer = Int(length & 0x3f) << 8 | Int(bytes[readCursor + 1])
                guard pointer < bytes.count, visitedPointers.insert(pointer).inserted else {
                    return nil
                }
                nextCursor = nextCursor ?? (readCursor + 2)
                readCursor = pointer
                jumpCount += 1
                continue
            }

            guard length & 0xc0 == 0, length <= 63 else {
                return nil
            }
            readCursor += 1
            let labelEnd = readCursor + Int(length)
            guard labelEnd <= bytes.count,
                  let label = String(bytes: bytes[readCursor..<labelEnd], encoding: .utf8),
                  !label.isEmpty,
                  label.unicodeScalars.allSatisfy({
                      $0.value > 0x20 && $0.value < 0x7f && $0.value != 0x2e
                  }) else {
                return nil
            }
            renderedLength += label.utf8.count + (labels.isEmpty ? 0 : 1)
            guard renderedLength <= 253 else {
                return nil
            }
            labels.append(label)
            readCursor = labelEnd
        }

        cursor = originalCursor
        return nil
    }

    private func normalizedName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return normalized.isEmpty || normalized.utf8.count > 253 ? nil : normalized
    }

    private func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
    }

    private func ipv4Address(at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return "\(bytes[offset]).\(bytes[offset + 1]).\(bytes[offset + 2]).\(bytes[offset + 3])"
    }

    private func ipv6Address(at offset: Int) -> String? {
        guard offset >= 0, offset + 16 <= bytes.count else { return nil }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { destination in
            destination.copyBytes(from: bytes[offset..<(offset + 16)])
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }
}
