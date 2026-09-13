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
    ] + automationTools

    private static var automationTools: [Tool] {
        let boolean: MCP.Value = .object(["type": "boolean"])
        let scope = enumProperty(["all", "displayed"], description: "Defaults to all. Displayed uses the targeted pane's source and filters.")
        let group = enumProperty(["apps", "domains", "ipv4", "ipv6", "tcp", "udp"], description: "Endpoint group. Defaults to apps.")
        let structured: MCP.Value = .object([
            "type": "object", "additionalProperties": false, "required": ["filters"],
            "properties": .object([
                "operator": enumProperty(["and", "or"], description: "Filter group operator."),
                "filters": .object(["type": "array", "maxItems": 5, "items": .object([
                    "type": "object", "additionalProperties": false, "required": ["query", "condition", "text"],
                    "properties": .object([
                        "id": stringProperty("Optional existing filter ID."),
                        "query": enumProperty(["anyText", "urlDomain", "protocol", "source", "destination", "sourcePort", "destinationPort", "client", "pid", "bundleIdentifier", "streamID", "direction", "tcpFlags", "tcpPayload", "decodeStatus", "interface", "length", "summary", "tags"], description: "Use anyText alone for a Wireshark expression."),
                        "condition": enumProperty(["contains", "notContains", "hasPrefix", "notHasPrefix", "hasSuffix", "notHasSuffix", "lessThan", "greaterThanOrEqual", "matchesRegex", "notMatchesRegex"], description: "Structured filter comparison."),
                        "text": stringProperty("Filter text.", maximumLength: 4096), "is_enabled": boolean,
                    ]),
                ])]),
            ]),
        ])
        return [
            readOnlyTool(.listWorkspaces, title: "List Workspaces", description: "List open workspaces and stable tab/pane IDs without loading inactive views.", properties: [:]),
            readOnlyTool(.listTabs, title: "List Tabs", description: "List live/offline tabs, ordering, selected tab, and split pane IDs.", properties: [:]),
            controlTool(.createTab, title: "Create Tab", description: "Create a live tab sharing the workspace capture. Requires PRO for an additional tab. Does not select it unless select=true.", properties: ["select": boolean]),
            controlTool(.selectTab, title: "Select Tab", description: "Select the targeted tab without activating the app.", properties: [:]),
            controlTool(.moveTab, title: "Move Tab", description: "Move the targeted tab to a zero-based index without changing selection.", properties: ["index": integerProperty("Destination tab index.", minimum: 0)], required: ["index"]),
            controlTool(.closeTab, title: "Close Tab", description: "Close a tab with confirm=true. Closing the last tab stops its capture and closes the workspace window.", properties: ["confirm": boolean], required: ["confirm"], destructive: true),
            readOnlyTool(.getPane, title: "Get Pane", description: "Read a pane's source, filters, packet selection, view mode, and packet counts without focusing it.", properties: [:]),
            controlTool(.updatePane, title: "Update Pane", description: "Update only supplied pane fields without changing focus or capture BPF. Empty filters clear them. Completion waits for filter application. Use endpoint from a statistics row to drill down.", properties: [
                "mode": enumProperty(["packets", "overview"], description: "Pane view mode."),
                "source_id": stringProperty("Exact source_id from list_sources."),
                "display_filter": stringProperty("Packet text filter; empty clears it.", maximumLength: 4096),
                "wireshark_filter": stringProperty("Wireshark display expression; empty clears it.", maximumLength: 4096),
                "structured_filter": structured,
                "quick_filters": .object(["type": "array", "maxItems": 11, "items": enumProperty(["all", "tcp", "udp", "dns", "http", "tls", "websocket", "clientHello", "serverHello", "errors"], description: "Quick filter ID.")]),
                "packet_id": .object(["type": ["string", "null"], "description": "Unsigned decimal packet ID; null clears selection."]),
                "endpoint": .object(["type": ["object", "null"], "required": ["group", "key"], "additionalProperties": false,
                                     "properties": .object(["group": group, "key": stringProperty("Exact endpoint key from get_endpoint_statistics.")])]),
            ]),
            controlTool(.setSplitView, title: "Set Split View", description: "Set enabled=true or false. Supports two panes sharing one capture. Opening a second pane requires PRO and preserves focus.", properties: ["enabled": boolean], required: ["enabled"]),
            controlTool(.focusPane, title: "Focus Pane", description: "Select the target tab and focus the specified pane without activating the app.", properties: [:]),
            readOnlyTool(.listSources, title: "List Sources", description: "List source selection IDs for apps, domains, files, and other sidebar items. No source selection is changed.", properties: ["offset": integerProperty("Result offset.", minimum: 0), "limit": integerProperty("Page size, defaults to 50.", minimum: 1, maximum: 500)]),
            readOnlyTool(.getOverviewStatistics, title: "Get Overview Statistics", description: "Return full-source Overview totals, time range, protocol breakdown, top apps/destinations, and bounded timeline. Unlike get_capture_overview, this returns dashboard analysis.", properties: [:]),
            readOnlyTool(.getEndpointStatistics, title: "Get Endpoint Statistics", description: "Aggregate a complete capture or displayed pane scope without opening Statistics. Returns endpoint identifiers for drill-down. Defaults to Apps sorted by bytes descending.", properties: [
                "group": group, "scope": scope, "search": stringProperty("Search endpoint fields.", maximumLength: 4096),
                "sort": enumProperty(["address", "port", "protocol", "client", "domain", "packets", "bytes", "tx_packets", "tx_bytes", "rx_packets", "rx_bytes", "summary"], description: "Sort column."),
                "order": enumProperty(["asc", "desc"], description: "Sort direction, defaults to desc."),
                "offset": integerProperty("Result offset.", minimum: 0), "limit": integerProperty("Page size, defaults to 50.", minimum: 1, maximum: 500),
            ]),
            readOnlyTool(.followStream, title: "Follow Stream", description: "Follow the TCP or UDP stream containing a packet, including DNS. Returns bounded payload records without opening a window. When redaction is enabled, payloads are omitted and payload_redacted=true.", properties: [
                "packet_id": stringProperty("Unsigned decimal packet ID."),
                "protocol": enumProperty(["auto", "tcp", "udp"], description: "Transport protocol, defaults to auto."),
                "direction": enumProperty(["both", "client-to-server", "server-to-client"], description: "Direction, defaults to both."),
                "encoding": enumProperty(["text", "hex", "base64"], description: "Payload encoding, defaults to text."),
                "max_bytes": integerProperty("Payload byte limit, defaults to 4 MiB.", minimum: 1, maximum: 4194304),
                "max_records": integerProperty("Record limit, defaults to 10000.", minimum: 1, maximum: 10000),
            ], required: ["packet_id"]),
            controlTool(.importCapture, title: "Import Capture", description: "Import absolute pcap/pcapng paths or one tcpviewsession. Defaults to creating and selecting an offline tab. Supplying tab_id replaces that tab, requires confirm=true, and preserves selection by default.", properties: [
                "paths": .object(["type": "array", "minItems": 1, "maxItems": 100, "items": stringProperty("Absolute capture path.")]),
                "select": boolean, "confirm": boolean,
            ], required: ["paths"], destructive: true),
            controlTool(.exportSession, title: "Export Session", description: "Export the targeted pane's source to an explicit absolute tcpviewsession path. Existing destinations require overwrite=true.", properties: ["path": stringProperty("Absolute destination path."), "overwrite": boolean], required: ["path"], destructive: true),
        ]
    }

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
            inputSchema: objectSchema(properties: properties, required: required, includesTarget: command != .listWorkspaces),
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
            inputSchema: objectSchema(properties: properties, required: required, includesTarget: command != .listWorkspaces),
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
            "scope": enumProperty(["all", "displayed"], description: "Read all captured packets or the targeted pane's displayed packets. Defaults to all."),
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
        required: [String] = [],
        includesTarget: Bool = true
    ) -> MCP.Value {
        var properties = properties
        if includesTarget {
            for key in ["workspace_id", "tab_id", "pane_id"] {
                properties[key] = .object(["type": "string", "format": "uuid", "description": "Stable target UUID from list_workspaces or list_tabs. Omission uses the current selection. Explicit targets preserve selection."])
            }
        }
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
