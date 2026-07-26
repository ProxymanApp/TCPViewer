//
//  TCPViewerMCPToolCatalog.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import MCP

enum TCPViewerMCPToolCatalog {
    static let tools: [Tool] = [
        readOnlyTool(
            .getAppStatus,
            title: "Get TCP Viewer Status",
            description: "Check TCP Viewer version, PRO authorization, redaction state, active window, capture phase, and packet count.",
            properties: [:]
        ),
        readOnlyTool(
            .getCaptureOverview,
            title: "Get Capture Overview",
            description: "Get the active capture state, packet and issue counts, interface selection, persistent BPF capture filter, and available controls.",
            properties: [:]
        ),
        readOnlyTool(
            .listInterfaces,
            title: "List Capture Interfaces",
            description: "List capture interfaces, addresses, availability, permissions, capabilities, and current selection.",
            properties: [:]
        ),
        Tool(
            name: TCPViewerMCPCommand.queryPackets.rawValue,
            title: "Query Packets",
            description: "Read and filter packets that TCP Viewer has already captured. Use this by default when the user asks to filter, find, or show packets. It does not change packet capture or TCP Viewer's Filter field. Supports bounded AND/OR filters, protocol, domain, packet ID, and stream constraints; results are paginated and newest-first by default.",
            inputSchema: packetQuerySchema(),
            annotations: readOnlyAnnotations,
            outputSchema: objectOutputSchema
        ),
        Tool(
            name: TCPViewerMCPCommand.summarizeCapture.rawValue,
            title: "Summarize Capture",
            description: "Aggregate packet, byte, protocol, domain, client, and time-range statistics over a bounded filtered capture window.",
            inputSchema: packetQuerySchema(includePagination: false),
            annotations: readOnlyAnnotations,
            outputSchema: objectOutputSchema
        ),
        readOnlyTool(
            .getPacketDetails,
            title: "Get Packet Details",
            description: "Decode one packet into a bounded protocol-detail tree. Sensitive field values are scrubbed when redaction is enabled.",
            properties: [
                "packet_id": stringProperty("Packet ID as an unsigned decimal string."),
                "max_depth": integerProperty("Maximum returned detail-tree depth.", minimum: 0, maximum: 12),
                "max_nodes": integerProperty("Maximum returned detail nodes.", minimum: 1, maximum: 5_000),
            ],
            required: ["packet_id"]
        ),
        readOnlyTool(
            .getPacketBytes,
            title: "Get Packet Bytes",
            description: "Return a bounded raw-byte range in hex or base64. This tool is blocked while sensitive-data redaction is enabled because arbitrary binary payloads cannot be safely scrubbed.",
            properties: [
                "packet_id": stringProperty("Packet ID as an unsigned decimal string."),
                "offset": integerProperty("Zero-based byte offset.", minimum: 0),
                "length": integerProperty("Number of bytes, capped at 65536.", minimum: 1, maximum: 65_536),
                "encoding": enumProperty(["hex", "base64"], description: "Output encoding."),
            ],
            required: ["packet_id"]
        ),
        Tool(
            name: TCPViewerMCPCommand.listStreamPackets.rawValue,
            title: "List Stream Packets",
            description: "List packets in one TCP or UDP stream with the same bounded filters and pagination as query_packets.",
            inputSchema: packetQuerySchema(required: ["stream_id"]),
            annotations: readOnlyAnnotations,
            outputSchema: objectOutputSchema
        ),
        Tool(
            name: TCPViewerMCPCommand.exportPackets.rawValue,
            title: "Export Packets",
            description: "Export selected or filtered packets to a PCAP or PCAPNG file at an explicit absolute path. Existing files require overwrite=true.",
            inputSchema: exportSchema(),
            annotations: .init(
                title: "Export Packets",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            ),
            outputSchema: objectOutputSchema
        ),
        controlTool(
            .startCapture,
            title: "Start Capture",
            description: "Start a new live capture and clear packets currently in the active window. capture_filter is a persistent libpcap/BPF capture filter for future packet collection, not a packet query or TCP Viewer's Filter field. Use query_packets for ordinary packet filtering. Before setting a non-empty capture_filter, explain the distinction to the user, obtain explicit confirmation, and pass confirm_bpf_filter=true. Omitting capture_filter preserves the current BPF filter; passing an empty string clears it.",
            properties: [
                "interface_id": stringProperty("Interface ID from list_interfaces.", maximumLength: 256),
                "capture_filter": stringProperty(
                    "Persistent libpcap/BPF expression controlling which future packets are collected. Nonmatching packets are not captured. This is not a packet query or the TCP Viewer Filter field. A non-empty value requires confirm_bpf_filter=true; omission preserves the current BPF filter and an empty string clears it.",
                    maximumLength: 4_096
                ),
                "confirm_bpf_filter": .object([
                    "type": "boolean",
                    "description": "Set true only after the user explicitly confirms they want the non-empty BPF capture filter, understanding that it excludes nonmatching traffic from capture.",
                ]),
            ],
            destructive: true
        ),
        controlTool(.pauseCapture, title: "Pause Capture", description: "Pause the active live capture.", properties: [:]),
        controlTool(.resumeCapture, title: "Resume Capture", description: "Resume a paused live capture.", properties: [:]),
        controlTool(.stopCapture, title: "Stop Capture", description: "Stop the active live capture.", properties: [:]),
        Tool(
            name: TCPViewerMCPCommand.clearPackets.rawValue,
            title: "Clear Packets",
            description: "Remove every packet from the active TCP Viewer window. Requires confirm=true.",
            inputSchema: objectSchema(
                properties: ["confirm": .object(["type": "boolean", "description": "Must be true to clear packets."])],
                required: ["confirm"]
            ),
            annotations: .init(
                title: "Clear Packets",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            ),
            outputSchema: objectOutputSchema
        ),
        controlTool(
            .revealPacket,
            title: "Reveal Packet",
            description: "Select one packet in TCP Viewer and open its inspector.",
            properties: ["packet_id": stringProperty("Packet ID as an unsigned decimal string.")],
            required: ["packet_id"]
        ),
    ]

    static func tool(named name: String) -> Tool? {
        tools.first { $0.name == name }
    }

    private static let readOnlyAnnotations = Tool.Annotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )
    private static let objectOutputSchema: MCP.Value = .object([
        "type": "object",
        "additionalProperties": true,
    ])

    private static func readOnlyTool(
        _ command: TCPViewerMCPCommand,
        title: String,
        description: String,
        properties: [String: MCP.Value],
        required: [String] = []
    ) -> Tool {
        Tool(
            name: command.rawValue,
            title: title,
            description: description,
            inputSchema: objectSchema(properties: properties, required: required),
            annotations: readOnlyAnnotations,
            outputSchema: objectOutputSchema
        )
    }

    private static func controlTool(
        _ command: TCPViewerMCPCommand,
        title: String,
        description: String,
        properties: [String: MCP.Value],
        required: [String] = [],
        destructive: Bool = false
    ) -> Tool {
        Tool(
            name: command.rawValue,
            title: title,
            description: description,
            inputSchema: objectSchema(properties: properties, required: required),
            annotations: .init(
                title: title,
                readOnlyHint: false,
                destructiveHint: destructive,
                idempotentHint: false,
                openWorldHint: false
            ),
            outputSchema: objectOutputSchema
        )
    }

    private static func packetQuerySchema(
        includePagination: Bool = true,
        required: [String] = []
    ) -> MCP.Value {
        var properties: [String: MCP.Value] = [
            "filters": .object([
                "type": "array",
                "maxItems": 20,
                "description": "Packet filters combined with the combination parameter.",
                "items": .object([
                    "type": "object",
                    "additionalProperties": false,
                    "properties": .object([
                        "field": enumProperty([
                            "packet_id", "packet_number", "protocol", "domain", "source_address",
                            "destination_address", "address", "source_port", "destination_port", "port",
                            "client", "bundle_id", "direction", "decode_status", "info", "interface",
                            "stream_id", "length", "tcp_flags", "truncated", "text",
                        ], description: "Packet field to inspect."),
                        "operator": enumProperty([
                            "equals", "not_equals", "contains", "not_contains", "starts_with", "ends_with",
                            "greater_than", "greater_than_or_equal", "less_than", "less_than_or_equal", "exists",
                        ], description: "Comparison operator."),
                        "value": .object(["description": "String, number, or boolean comparison value."]),
                        "case_sensitive": .object(["type": "boolean", "description": "Use case-sensitive string matching."]),
                    ]),
                    "required": .array(["field"]),
                ]),
            ]),
            "combination": enumProperty(["and", "or"], description: "How filters are combined."),
            "protocols": stringArrayProperty(
                "Protocol names; these constraints are ANDed with filters.",
                maximumItems: TCPViewerMCPQueryLimit.maximumProtocolCount,
                maximumStringLength: 256
            ),
            "domains": stringArrayProperty(
                "SNI domains or domain fragments; these constraints are ANDed with filters.",
                maximumItems: TCPViewerMCPQueryLimit.maximumDomainCount,
                maximumStringLength: 255
            ),
            "packet_ids": stringArrayProperty(
                "Packet IDs as unsigned decimal strings.",
                maximumItems: TCPViewerMCPQueryLimit.maximumPacketIDCount,
                maximumStringLength: 20
            ),
            "stream_id": integerProperty("TCP or UDP stream ID.", minimum: 0, maximum: Int(UInt32.max)),
            "scan_limit": integerProperty("Maximum packets scanned, capped at 100000.", minimum: 1, maximum: 100_000),
            "scan_offset": integerProperty(
                "Packets to skip from the selected edge before scanning. Use next_scan_offset to traverse bounded windows.",
                minimum: 0
            ),
            "order": enumProperty(["recent", "oldest"], description: "Scan newest or oldest packets first."),
        ]
        if includePagination {
            properties["offset"] = integerProperty(
                "Matched-result offset.",
                minimum: 0,
                maximum: TCPViewerMCPQueryLimit.maximumOffset
            )
            properties["limit"] = integerProperty("Maximum returned packets, capped at 500.", minimum: 1, maximum: 500)
        }
        return objectSchema(properties: properties, required: required)
    }

    private static func exportSchema() -> MCP.Value {
        var properties = packetQuerySchema(includePagination: false).objectValue?["properties"]?.objectValue ?? [:]
        properties["path"] = stringProperty(
            "Absolute destination path. The format extension is added when omitted.",
            maximumLength: 4_096
        )
        properties["format"] = enumProperty(["pcap", "pcapng"], description: "Capture file format.")
        properties["overwrite"] = .object(["type": "boolean", "description": "Explicitly allow replacement of an existing regular file."])
        properties["all"] = .object(["type": "boolean", "description": "Export the bounded scan window when no filters are supplied."])
        return objectSchema(properties: properties, required: ["path"])
    }

    private static func objectSchema(
        properties: [String: MCP.Value],
        required: [String] = []
    ) -> MCP.Value {
        var schema: [String: MCP.Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(MCP.Value.string))
        }
        return .object(schema)
    }

    private static func stringProperty(_ description: String, maximumLength: Int? = nil) -> MCP.Value {
        var property: [String: MCP.Value] = [
            "type": "string",
            "description": .string(description),
        ]
        if let maximumLength {
            property["maxLength"] = .int(maximumLength)
        }
        return .object(property)
    }

    private static func integerProperty(
        _ description: String,
        minimum: Int,
        maximum: Int? = nil
    ) -> MCP.Value {
        var property: [String: MCP.Value] = [
            "type": "integer",
            "description": .string(description),
            "minimum": .int(minimum),
        ]
        if let maximum {
            property["maximum"] = .int(maximum)
        }
        return .object(property)
    }

    private static func enumProperty(_ values: [String], description: String) -> MCP.Value {
        .object([
            "type": "string",
            "description": .string(description),
            "enum": .array(values.map(MCP.Value.string)),
        ])
    }

    private static func stringArrayProperty(
        _ description: String,
        maximumItems: Int,
        maximumStringLength: Int
    ) -> MCP.Value {
        .object([
            "type": "array",
            "description": .string(description),
            "maxItems": .int(maximumItems),
            "items": .object([
                "type": "string",
                "maxLength": .int(maximumStringLength),
            ]),
        ])
    }
}
