//
//  LibpcapBindings.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 28/5/26.
//

import Darwin
import Foundation

private let pcapErrorBufferSize = 256

struct pcap_pkthdr {
    var ts: timeval
    var caplen: UInt32
    var len: UInt32
}

struct bpf_program {
    var bf_len: UInt32 = 0
    var bf_insns: UnsafeMutableRawPointer?
}

@_silgen_name("pcap_open_dead")
private func pcap_open_dead(_ linktype: Int32, _ snaplen: Int32) -> OpaquePointer?

@_silgen_name("pcap_open_live")
private func pcap_open_live(
    _ device: UnsafePointer<CChar>,
    _ snaplen: Int32,
    _ promisc: Int32,
    _ to_ms: Int32,
    _ errbuf: UnsafeMutablePointer<CChar>
) -> OpaquePointer?

@_silgen_name("pcap_compile")
private func pcap_compile(
    _ p: OpaquePointer?,
    _ fp: UnsafeMutablePointer<bpf_program>,
    _ str: UnsafePointer<CChar>,
    _ optimize: Int32,
    _ netmask: UInt32
) -> Int32

@_silgen_name("pcap_setfilter")
private func pcap_setfilter(_ p: OpaquePointer?, _ fp: UnsafeMutablePointer<bpf_program>) -> Int32

@_silgen_name("pcap_freecode")
private func pcap_freecode(_ fp: UnsafeMutablePointer<bpf_program>)

@_silgen_name("pcap_close")
private func pcap_close(_ p: OpaquePointer?)

@_silgen_name("pcap_geterr")
private func pcap_geterr(_ p: OpaquePointer?) -> UnsafePointer<CChar>?

@_silgen_name("pcap_next_ex")
private func pcap_next_ex(
    _ p: OpaquePointer?,
    _ pkt_header: UnsafeMutablePointer<UnsafePointer<pcap_pkthdr>?>?,
    _ pkt_data: UnsafeMutablePointer<UnsafePointer<UInt8>?>?
) -> Int32

@_silgen_name("pcap_breakloop")
private func pcap_breakloop(_ p: OpaquePointer?)

@_silgen_name("pcap_stats")
private func pcap_stats(_ p: OpaquePointer?, _ ps: UnsafeMutablePointer<pcap_stat>) -> Int32

@_silgen_name("pcap_datalink")
private func pcap_datalink(_ p: OpaquePointer?) -> Int32

struct pcap_stat {
    var ps_recv: UInt32 = 0
    var ps_drop: UInt32 = 0
    var ps_ifdrop: UInt32 = 0
}

enum Libpcap {
    static let dltNull: Int32 = 0
    static let dltEthernet: Int32 = 1
    static let dltRaw: Int32 = 12

    static func validateFilter(_ expression: String, linkType: Int32 = dltEthernet, snapshotLength: Int32 = 65_535) -> String? {
        guard let handle = pcap_open_dead(linkType, snapshotLength) else {
            return "libpcap could not create a validation handle."
        }
        defer { pcap_close(handle) }

        var program = bpf_program()
        let result = expression.withCString { filterPointer in
            pcap_compile(handle, &program, filterPointer, 1, 0xffff_ffff)
        }
        defer {
            if program.bf_insns != nil {
                pcap_freecode(&program)
            }
        }

        guard result == 0 else {
            guard let errorPointer = pcap_geterr(handle) else {
                return "Invalid libpcap syntax."
            }
            return String(cString: errorPointer)
        }
        return nil
    }

    static func openLive(interfaceName: String, options: PCPPNativeCaptureOptionsDescriptor) throws -> OpaquePointer {
        var errorBuffer = [CChar](repeating: 0, count: pcapErrorBufferSize)
        let handle = interfaceName.withCString { namePointer in
            pcap_open_live(
                namePointer,
                Int32(max(options.snapshotLength, 1)),
                options.promiscuousMode ? 1 : 0,
                Int32(max(options.readTimeoutMilliseconds, 1)),
                &errorBuffer
            )
        }

        guard let handle else {
            let message = String(cString: errorBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeNSError(.captureStartFailed, message.isEmpty ? "libpcap could not open \(interfaceName)." : message)
        }

        if let expression = options.captureFilterExpression, !expression.isEmpty {
            do {
                try setFilter(expression, on: handle)
            } catch {
                pcap_close(handle)
                throw error
            }
        }

        return handle
    }

    static func setFilter(_ expression: String, on handle: OpaquePointer) throws {
        var program = bpf_program()
        let compileResult = expression.withCString { filterPointer in
            pcap_compile(handle, &program, filterPointer, 1, 0xffff_ffff)
        }
        defer {
            if program.bf_insns != nil {
                pcap_freecode(&program)
            }
        }

        guard compileResult == 0 else {
            throw NativeNSError(.invalidFilter, "Invalid libpcap syntax: \(pcapError(handle))")
        }

        guard pcap_setfilter(handle, &program) == 0 else {
            throw NativeNSError(.invalidFilter, "libpcap could not apply the capture filter: \(pcapError(handle))")
        }
    }

    static func nextPacket(from handle: OpaquePointer) -> (header: pcap_pkthdr, bytes: Data)? {
        var headerPointer: UnsafePointer<pcap_pkthdr>?
        var dataPointer: UnsafePointer<UInt8>?
        let result = pcap_next_ex(handle, &headerPointer, &dataPointer)
        guard result == 1,
              let headerPointer,
              let dataPointer else {
            return nil
        }

        let header = headerPointer.pointee
        let bytes = Data(bytes: dataPointer, count: Int(header.caplen))
        return (header, bytes)
    }

    static func stats(for handle: OpaquePointer) -> pcap_stat? {
        var stats = pcap_stat()
        guard pcap_stats(handle, &stats) == 0 else {
            return nil
        }
        return stats
    }

    static func dataLink(for handle: OpaquePointer) -> Int32 {
        let dataLink = pcap_datalink(handle)
        return dataLink >= 0 ? dataLink : dltEthernet
    }

    static func close(_ handle: OpaquePointer?) {
        guard let handle else {
            return
        }
        pcap_close(handle)
    }

    static func breakLoop(_ handle: OpaquePointer?) {
        guard let handle else {
            return
        }
        pcap_breakloop(handle)
    }

    private static func pcapError(_ handle: OpaquePointer) -> String {
        guard let pointer = pcap_geterr(handle) else {
            return "unknown libpcap error"
        }
        let message = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "unknown libpcap error" : message
    }
}
