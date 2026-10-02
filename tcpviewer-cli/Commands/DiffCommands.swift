//
//  DiffCommands.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import ArgumentParser
import Foundation

struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare packets through the Diff pool.",
        subcommands: [DiffListCommand.self, DiffAddCommand.self, DiffSetCommand.self, DiffRemoveCommand.self,
                      DiffCompareCommand.self, DiffOpenCommand.self]
    )
}

enum DiffDisplayModeOption: String, ExpressibleByArgument {
    case sideBySide = "side-by-side"
    case unified
    // The app's JSON contract uses snake-case enum values.
    var parameter: String { self == .sideBySide ? "side_by_side" : "unified" }
}

enum DiffContentOption: String, ExpressibleByArgument { case details, bytes }

private func validateEntryIDs(_ ids: [String?]) throws {
    for id in ids.compactMap({ $0 }) {
        guard UUID(uuidString: id) != nil else { throw ValidationError("Entry IDs must be UUIDs from diff list.") }
    }
}

struct DiffListCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Diff pool items, their sides, and the pool limit.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.diffList) }
}

struct DiffAddCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Snapshot packets from the targeted tab into the Diff pool.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "Packet IDs from the targeted capture.") var packetIDs: [String]

    func validate() throws {
        guard (1...500).contains(packetIDs.count), packetIDs.allSatisfy({ UInt64($0) != nil }) else {
            throw ValidationError("diff add requires 1 to 500 unsigned decimal packet IDs.")
        }
        if global.target.scope != nil { throw ValidationError("diff add does not accept --scope.") }
    }

    func run() throws { try execute(.diffAdd, params: ["packet_ids": .array(packetIDs.map(TCPViewerCLIValue.string))]) }
}

struct DiffSetCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Choose the Left and Right items and how the Diff window compares them.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Option(name: .long, help: "Entry ID to place on the Left.") var left: String?
    @Option(name: .long, help: "Entry ID to place on the Right.") var right: String?
    @Flag(name: .long) var clearLeft = false
    @Flag(name: .long) var clearRight = false
    @Option(name: .long, help: "side-by-side or unified.") var mode: DiffDisplayModeOption?
    @Option(name: .long, help: "details or bytes.") var content: DiffContentOption?

    func validate() throws {
        try validateEntryIDs([left, right])
        if (left != nil && clearLeft) || (right != nil && clearRight) { throw ValidationError("Choose an entry ID or clear that side.") }
        if let left, left.lowercased() == right?.lowercased() { throw ValidationError("--left and --right must be different entries.") }
    }

    func run() throws {
        var params: [String: TCPViewerCLIValue] = [:]
        if let left { params["left_entry_id"] = .string(left) }
        if let right { params["right_entry_id"] = .string(right) }
        if clearLeft { params["left_entry_id"] = .null }
        if clearRight { params["right_entry_id"] = .null }
        if let mode { params["display_mode"] = .string(mode.parameter) }
        if let content { params["content"] = .string(content.rawValue) }
        try execute(.diffSet, params: params)
    }
}

struct DiffRemoveCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove items from the Diff pool. Captured packets are not affected.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "Entry IDs from diff list.") var entryIDs: [String] = []
    @Flag(name: .long, help: "Remove every item.") var all = false
    @Flag(name: .long, help: "Confirm removal of every item.") var yes = false

    func validate() throws {
        try validateEntryIDs(entryIDs)
        guard all == entryIDs.isEmpty, entryIDs.count <= 500 else { throw ValidationError("diff remove accepts 1 to 500 entry IDs, or --all.") }
        if all && !yes { throw ValidationError("diff remove --all requires --yes.") }
    }

    func run() throws {
        try execute(.diffRemove, params: all ? ["all": .bool(true), "confirm": .bool(yes)]
                                             : ["entry_ids": .array(entryIDs.map(TCPViewerCLIValue.string))])
    }
}

struct DiffCompareCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "compare", abstract: "Compare two Diff pool items without changing the Diff window.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Option(name: .long, help: "Left entry ID. Defaults to the pool's Left item.") var left: String?
    @Option(name: .long, help: "Right entry ID. Defaults to the pool's Right item.") var right: String?
    @Option(name: .long, help: "details or bytes. Defaults to the Diff window's setting.") var content: DiffContentOption?
    @Option(name: .long, help: "Unchanged lines around each detail change.") var context = 3
    @Option(name: .long, help: "Maximum diff lines or byte changes.") var limit = 1_000

    func validate() throws {
        try validateEntryIDs([left, right])
        guard (0...20).contains(context) else { throw ValidationError("--context must be between 0 and 20.") }
        guard (1...5_000).contains(limit) else { throw ValidationError("--limit must be between 1 and 5000.") }
    }

    func run() throws {
        var params: [String: TCPViewerCLIValue] = ["context": .int(context), "limit": .int(limit)]
        if let left { params["left_entry_id"] = .string(left) }
        if let right { params["right_entry_id"] = .string(right) }
        if let content { params["content"] = .string(content.rawValue) }
        try execute(.diffCompare, params: params, defaultTimeout: 120)
    }
}

struct DiffOpenCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Show the Diff window without activating TCP Viewer.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.diffOpen) }
}
