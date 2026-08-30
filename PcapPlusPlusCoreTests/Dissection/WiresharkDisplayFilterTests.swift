//
//  WiresharkDisplayFilterTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkDisplayFilterTests {
    private struct SyntaxCategory {
        let name: String
        let expressions: [String]
    }

    @Test func stableSyntaxChecklistCompilesEverySupportedCategory() {
        let categories = Self.syntaxCategories
        #expect(categories.count == 18)

        for category in categories {
            for expression in category.expressions {
                let validation = WiresharkEpanSession.validateDisplayFilter(expression)
                #expect(
                    validation.status == .valid,
                    "\(category.name) rejected `\(expression)`: \(validation.diagnostics.map(\.message))"
                )
            }
        }
    }

    @Test func invalidSyntaxReturnsNativeRangesAndMessages() {
        var rangedDiagnosticCount = 0
        for expression in [
            "unknown.tcpviewer.field == 1",
            "tcp.port ==",
            "(tcp.port == 443",
            "tcp.port in {80,",
            "tcp.port == \"https\"",
            "http.host matches \"[\"",
        ] {
            let validation = WiresharkEpanSession.validateDisplayFilter(expression)
            #expect(validation.status == .invalid)
            #expect(validation.diagnostics.first?.severity == .error)
            #expect(validation.diagnostics.first?.message.isEmpty == false)
            if validation.diagnostics.first?.range != nil {
                rangedDiagnosticCount += 1
            }
        }
        #expect(rangedDiagnosticCount >= 3)
    }

    @Test func dollarTokensAreRejectedOnlyOutsideStringLiterals() {
        let macro = WiresharkEpanSession.validateDisplayFilter("$private_ipv4(ip.src)")
        #expect(macro.status == .invalid)
        #expect(macro.diagnostics.first?.range == DisplayFilterSourceRange(utf8StartOffset: 0, utf8Length: 13))

        let selectedField = WiresharkEpanSession.validateDisplayFilter("frame.number < $frame.number")
        #expect(selectedField.status == .invalid)
        #expect(selectedField.diagnostics.first?.range == DisplayFilterSourceRange(utf8StartOffset: 15, utf8Length: 13))

        #expect(WiresharkEpanSession.validateDisplayFilter("http.host == \"$value\"").status == .valid)
        #expect(WiresharkEpanSession.validateDisplayFilter("http.host == r\"$value\"").status == .valid)
    }

    @Test func blankInputIsAValidClearOperation() {
        let validation = WiresharkEpanSession.validateDisplayFilter("  \n\t ")
        #expect(validation.status == .valid)
        #expect(validation.normalizedExpression.isEmpty)
        #expect(validation.diagnostics.isEmpty)
    }

    @Test func deprecatedTokenRemainsApplicableAndReportsAWarning() {
        let validation = WiresharkEpanSession.validateDisplayFilter("bootp")

        #expect(validation.status == .valid)
        #expect(validation.diagnostics.contains { diagnostic in
            diagnostic.severity == .warning && diagnostic.message.localizedCaseInsensitiveContains("deprecated")
        })
    }

    private static let syntaxCategories: [SyntaxCategory] = [
        SyntaxCategory(name: "field existence and columns", expressions: [
            "frame",
            "tcp.port",
            "_ws.col.info",
            "len(_ws.col.protocol) >= 0",
        ]),
        SyntaxCategory(name: "comparison operands", expressions: [
            "ip.proto == 6",
            "tcp.srcport == tcp.dstport",
            "len(frame) > 0",
        ]),
        SyntaxCategory(name: "comparison aliases", expressions: [
            "ip.version eq 4", "ip.version ne 6", "ip.version gt 1", "ip.version lt 7",
            "ip.version ge 4", "ip.version le 4", "ip.version == 4", "ip.version != 6",
            "ip.version > 1", "ip.version < 7", "ip.version >= 4", "ip.version <= 4",
        ]),
        SyntaxCategory(name: "multi occurrence", expressions: [
            "udp.port === 53", "udp.port !== 53", "any ip.addr > 1.1.1.1", "all ip.addr > 1.1.1.1",
            "tcp.port any_eq 443", "tcp.port all_eq 443", "tcp.port any_ne 443", "tcp.port all_ne 443",
        ]),
        SyntaxCategory(name: "contains and regex", expressions: [
            "tcp.payload contains \"GET\"",
            "http.request.method matches \"(?i)^get$\"",
            "http.request.method ~ r\"^GET$\"",
        ]),
        SyntaxCategory(name: "logical operators", expressions: [
            "not tcp", "!udp", "tcp and ip", "tcp && ip", "tcp xor udp", "tcp ^^ udp",
            "tcp or udp", "tcp || udp", "tcp or udp and ip", "(tcp or udp) and ip",
        ]),
        SyntaxCategory(name: "numeric boolean and time literals", expressions: [
            "frame.len > 10", "frame.len > 012", "frame.len > 0xa", "frame.len > 0b1010",
            "frame.len > 'P'", "frame.ignored == true", "icmp.resptime > 1.25",
            "frame.time > \"2002-12-31 13:54:31.3 UTC\"",
        ]),
        SyntaxCategory(name: "typed literals", expressions: [
            "http.request.method == \"\\u00e9\"",
            "smb.path contains r\"\\SERVER\\SHARE\"",
            "tcp.payload contains 47:45:54",
            "eth.addr == 00:11:22:33:44:55",
            "thread_bcn.epid == 00:11:22:33:44:55:66:77",
            "ip.addr == 192.168.1.1", "ipv6.addr == 2001:db8::1",
            "ip.addr == 192.168.0.0/16", "typeinfo.guid == 00000000-0000-0000-0000-000000000000",
            "snmp.name == 1.3.6.1",
        ]),
        SyntaxCategory(name: "slices", expressions: [
            "frame[5:5] == 11:22:33:44:55", "frame[5-10] == 11:22:33:44:55:66",
            "frame[5] == 11", "frame[:20] contains be:ef", "frame[20:] contains 12:34",
            "frame[-4:] contains 12:34", "frame[0:2,4:2] contains 00:01",
        ]),
        SyntaxCategory(name: "layer and raw field", expressions: [
            "ip.addr#2 == 4.4.4.4", "ip.dst#[-1] == 8.8.8.8", "@tcp.port[1] == 0xc3",
        ]),
        SyntaxCategory(name: "membership", expressions: [
            "tcp.port in {80, 443, 8080}", "tcp.port in {4430..4434}",
            "ip.addr in {10.0.0.5 .. 10.0.0.9}", "frame.time_delta in {10 .. 10.5}",
        ]),
        SyntaxCategory(name: "implicit conversions", expressions: [
            "tcp.payload contains \"GET\"", "frame[60:2] gt \"PQ\"", "tcp.checksum.status == \"Unverified\"",
        ]),
        SyntaxCategory(name: "bitwise aliases", expressions: [
            "tcp.flags & 0x8", "tcp.flags bitand 0x8", "tcp.flags bitwise_and 0x8",
        ]),
        SyntaxCategory(name: "arithmetic", expressions: [
            "udp.dstport == udp.srcport + 1", "udp.srcport == udp.dstport - 1",
            "udp.port * {10 / {5 - 4}} >= 0", "frame.len % 2 == 0",
        ]),
        SyntaxCategory(name: "built in functions", expressions: [
            "upper(http.host) contains \"EXAMPLE\"", "lower(http.host) contains \"example\"",
            "len(frame) > 0", "count(ip.addr) >= 0", "string(frame.number) matches \"[0-9]+\"",
            "vals(tls.handshake.type) contains \"Client\"", "dec(frame.number) == \"1\"",
            "hex(frame.number) == \"1\"", "float(frame.number) >= 0", "double(frame.number) >= 0",
            "max(tcp.srcport, tcp.dstport) >= 0", "min(tcp.srcport, tcp.dstport) >= 0", "udp.dstport == abs(-67)",
        ]),
        SyntaxCategory(name: "IP functions", expressions: [
            "ip_special_name(ip.addr) contains \"\"", "ip_special_mask(ip.addr) >= 0",
            "ip_linklocal(ip.addr)", "ip_multicast(ip.addr)", "ip_rfc1918(ip.addr)", "ip_ula(ipv6.addr)",
        ]),
        SyntaxCategory(name: "warnings and deprecated forms", expressions: [
            "bootp", "tcp.checksum.status == Unverified",
        ]),
        SyntaxCategory(name: "explicit unsupported tokens", expressions: [
            "http.host == \"$literal\"", "http.host == r\"$literal\"",
        ]),
    ]
}
