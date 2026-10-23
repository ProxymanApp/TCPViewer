//
//  TCPViewerMCPInitializeCompatibilityTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/10/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerMCPInitializeCompatibilityTests {
    @Test func codexInitializeDropsObjectValuedExperimentalCapability() throws {
        let data = try encode(request(capabilities: [
            "experimental": ["codex/auth-change": [:]],
            "elicitation": ["form": [:], "url": [:]],
        ]))
        let expected = request(capabilities: [
            "experimental": [:],
            "elicitation": ["form": [:], "url": [:]],
        ])

        let normalized = TCPViewerMCPInitializeCompatibility.normalize(data)

        #expect(try decode(normalized) as? NSDictionary == expected as NSDictionary)
    }

    @Test func compatibleRequestsKeepTheirOriginalBytes() throws {
        let capabilitiesList: [[String: Any]] = [
            [:],
            ["experimental": [:]],
            ["experimental": ["foo": "bar", "codex/auth-change": "supported"]],
        ]
        for capabilities in capabilitiesList {
            let data = try encode(request(capabilities: capabilities))
            #expect(TCPViewerMCPInitializeCompatibility.normalize(data) == data)
        }
    }

    @Test func unsupportedValuesAreDroppedWithoutChangingOtherFields() throws {
        let values: [Any] = [[:], ["nested": ["enabled": true]], 123, NSNull(), true, [1, 2]]
        for value in values {
            let original = request(capabilities: [
                "experimental": ["example/unknown": value, "keep": "supported"],
                "roots": ["listChanged": true],
                "sampling": [:],
            ])
            let expected = request(capabilities: [
                "experimental": ["keep": "supported"],
                "roots": ["listChanged": true],
                "sampling": [:],
            ])

            let normalized = TCPViewerMCPInitializeCompatibility.normalize(try encode(original))

            #expect(try decode(normalized) as? NSDictionary == expected as NSDictionary)
            #expect(TCPViewerMCPInitializeCompatibility.normalize(normalized) == normalized)
        }
    }

    @Test func malformedAndUnrelatedMessagesPassThroughUnchanged() {
        let messages = [
            #"not JSON"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":null}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":[]}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":123}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":null}}}"#,
            #"{"jsonrpc":"2.0","method":"initialize","params":{"capabilities":{"experimental":{"foo":{}}}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"example","capabilities":{"experimental":{"foo":{}}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"experimental":{"foo":{}}}}}"#,
            #"[{"jsonrpc":"2.0","id":2,"method":"ping"}]"#,
        ]
        for message in messages {
            let data = Data(message.utf8)
            #expect(TCPViewerMCPInitializeCompatibility.normalize(data) == data, "\(message)")
        }
    }

    @Test func batchChangesOnlyInitializeRequests() throws {
        let initialize = request(capabilities: ["experimental": ["foo": [:]]])
        let toolCall: [String: Any] = [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["capabilities": ["experimental": ["foo": [:]]]],
        ]
        let expected: [Any] = [request(capabilities: ["experimental": [:]]), toolCall, NSNull()]

        let normalized = TCPViewerMCPInitializeCompatibility.normalize(try encode([initialize, toolCall, NSNull()]))

        #expect(try decode(normalized) as? NSArray == expected as NSArray)
    }

    private func request(capabilities: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": capabilities,
                "clientInfo": ["name": "codex-mcp-client", "version": "0.163.0"],
                "_meta": ["example": 42],
            ],
        ]
    }

    private func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func decode(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }
}
