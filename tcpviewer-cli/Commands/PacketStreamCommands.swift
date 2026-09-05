//
//  PacketStreamCommands.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import ArgumentParser
import Foundation

struct PacketsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "packets",
        abstract: "Query and inspect packets.",
        subcommands: [
            PacketsListCommand.self,
            PacketsSummaryCommand.self,
            PacketsDetailsCommand.self,
            PacketsBytesCommand.self,
            PacketsClearCommand.self,
            PacketsRevealCommand.self,
        ]
    )
}

struct PacketsListCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List bounded matching packets.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @OptionGroup var query: TCPViewerCLIPacketQueryOptions
    func validate() throws { try query.validate() }
    func run() throws { try execute(.packetsList, params: query.params()) }
}

struct PacketsSummaryCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "summary", abstract: "Summarize bounded matching packets.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @OptionGroup var query: TCPViewerCLIPacketQueryOptions
    func validate() throws { try query.validate() }
    func run() throws { try execute(.packetsSummary, params: query.params(includesPagination: false)) }
}

struct PacketsDetailsCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "details", abstract: "Decode one packet's protocol tree.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "Packet ID.") var packetID: String
    @Option(name: .long) var maxDepth = 12
    @Option(name: .long) var maxNodes = 5_000

    func validate() throws {
        guard UInt64(packetID) != nil else { throw ValidationError("packet-id must be an unsigned decimal integer.") }
        guard (0...12).contains(maxDepth) else { throw ValidationError("--max-depth must be between 0 and 12.") }
        guard (1...5_000).contains(maxNodes) else { throw ValidationError("--max-nodes must be between 1 and 5000.") }
    }

    func run() throws {
        try execute(.packetsDetails, params: [
            "packet_id": .string(packetID),
            "max_depth": .int(maxDepth),
            "max_nodes": .int(maxNodes),
        ])
    }
}

enum PacketBytesEncoding: String, ExpressibleByArgument {
    case hex
    case base64
}

struct PacketsBytesCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "bytes", abstract: "Read a bounded raw packet byte range.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "Packet ID.") var packetID: String
    @Option(name: .long) var offset = 0
    @Option(name: .long) var length = 4_096
    @Option(name: .long) var encoding: PacketBytesEncoding = .base64

    func validate() throws {
        guard UInt64(packetID) != nil else { throw ValidationError("packet-id must be an unsigned decimal integer.") }
        guard offset >= 0 else { throw ValidationError("--offset cannot be negative.") }
        guard (1...65_536).contains(length) else { throw ValidationError("--length must be between 1 and 65536.") }
    }

    func run() throws {
        try execute(.packetsBytes, params: [
            "packet_id": .string(packetID),
            "offset": .int(offset),
            "length": .int(length),
            "encoding": .string(encoding.rawValue),
        ])
    }
}

struct PacketsClearCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Remove every packet from the active window.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Flag(name: .long, help: "Confirm removal of all packets.") var yes = false
    func validate() throws { if !yes { throw ValidationError("packets clear requires --yes.") } }
    func run() throws { try execute(.packetsClear, params: ["confirm": .bool(true)]) }
}

struct PacketsRevealCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "reveal", abstract: "Reveal one packet in TCP Viewer.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "Packet ID.") var packetID: String
    func validate() throws { if UInt64(packetID) == nil { throw ValidationError("packet-id must be an unsigned decimal integer.") } }
    func run() throws { try execute(.packetsReveal, params: ["packet_id": .string(packetID)]) }
}

struct StreamCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream",
        abstract: "Inspect TCP or UDP streams.",
        subcommands: [StreamPacketsCommand.self, StreamFollowCommand.self]
    )
}

struct StreamPacketsCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "packets", abstract: "List packets in one stream.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "TCP or UDP stream ID.") var streamID: UInt32
    @OptionGroup var query: TCPViewerCLIPacketQueryOptions

    func validate() throws { try query.validate() }
    func run() throws {
        var params = try query.params()
        params["stream_id"] = .int(Int(streamID))
        try execute(.streamPackets, params: params)
    }
}

enum StreamFollowDirection: String, ExpressibleByArgument {
    case both
    case clientToServer = "client-to-server"
    case serverToClient = "server-to-client"
}

enum StreamFollowEncoding: String, ExpressibleByArgument {
    case text
    case hex
    case base64
}

struct StreamFollowCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "follow", abstract: "Follow the TCP or UDP stream containing one packet.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "Packet ID in the TCP or UDP stream.") var packetID: String
    @Option(name: .long) var direction: StreamFollowDirection = .both
    @Option(name: .long) var encoding: StreamFollowEncoding = .text
    @Option(name: .customLong("max-bytes")) var maxBytes = 4 * 1_024 * 1_024
    @Option(name: .customLong("max-records")) var maxRecords = 10_000

    func validate() throws {
        guard UInt64(packetID) != nil else { throw ValidationError("packet-id must be an unsigned decimal integer.") }
        guard (1...(4 * 1_024 * 1_024)).contains(maxBytes) else { throw ValidationError("--max-bytes must be between 1 and 4194304.") }
        guard (1...10_000).contains(maxRecords) else { throw ValidationError("--max-records must be between 1 and 10000.") }
    }

    func run() throws {
        try execute(.streamFollow, params: [
            "packet_id": .string(packetID),
            "direction": .string(direction.rawValue),
            "encoding": .string(encoding.rawValue),
            "max_bytes": .int(maxBytes),
            "max_records": .int(maxRecords),
        ], defaultTimeout: 300)
    }
}
