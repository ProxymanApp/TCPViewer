//
//  WorkspaceCommands.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 13/9/26.
//

import ArgumentParser
import Foundation

struct TCPViewerCLITargetOptions: ParsableArguments {
    @Option(name: .long, help: "Workspace UUID from workspace list.") var workspaceID: String?
    @Option(name: .long, help: "Tab UUID from tabs list.") var tabID: String?
    @Option(name: .long, help: "Pane UUID from tabs list.") var paneID: String?
    @Option(name: .long, help: "Packet scope: all or displayed.") var scope: String?

    func validate() throws {
        for value in [workspaceID, tabID, paneID].compactMap({ $0 }) {
            guard UUID(uuidString: value) != nil else { throw ValidationError("Target IDs must be UUIDs.") }
        }
        if let scope, !["all", "displayed"].contains(scope) { throw ValidationError("--scope must be all or displayed.") }
    }

    var params: [String: TCPViewerCLIValue] {
        var values: [String: TCPViewerCLIValue] = [:]
        for (key, value) in [("workspace_id", workspaceID), ("tab_id", tabID), ("pane_id", paneID), ("scope", scope)] {
            if let value { values[key] = .string(value) }
        }
        return values
    }
}

struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "workspace", abstract: "Discover open workspaces.", subcommands: [WorkspaceListCommand.self])
}
struct WorkspaceListCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List workspace, tab, and pane IDs.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.workspaceList) }
}
struct TabsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tabs", abstract: "Manage workspace tabs.", subcommands: [TabsListCommand.self, TabsCreateCommand.self, TabsSelectCommand.self, TabsMoveCommand.self, TabsCloseCommand.self])
}
struct TabsListCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List tabs without loading their views.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.tabsList) }
}
struct TabsCreateCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a live tab without selecting it.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Flag(name: .long, help: "Select the newly created tab.") var select = false
    func run() throws { try execute(.tabsCreate, params: ["select": .bool(select)]) }
}
struct TabsSelectCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "select", abstract: "Select the tab identified by --tab-id.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.tabsSelect) }
}
struct TabsMoveCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move the targeted tab to a zero-based index.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument var index: Int
    func validate() throws { if index < 0 { throw ValidationError("index must be nonnegative.") } }
    func run() throws { try execute(.tabsMove, params: ["index": .int(index)]) }
}
struct TabsCloseCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "close", abstract: "Close a tab. Closing the last tab also stops capture and closes its window.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Flag(name: .long) var yes = false
    func validate() throws { if !yes { throw ValidationError("tabs close requires --yes.") } }
    func run() throws { try execute(.tabsClose, params: ["confirm": .bool(yes)]) }
}
struct PaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pane", abstract: "Read and update independent pane state.", subcommands: [PaneGetCommand.self, PaneUpdateCommand.self, PaneFocusCommand.self])
}
struct PaneGetCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read a pane's filters, source, selection, and view mode.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.paneGet, defaultTimeout: 120) }
}
struct PaneFocusCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "focus", abstract: "Select the targeted tab and focus its pane without activating the app.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.paneFocus) }
}
struct PaneUpdateCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Change the targeted pane without changing focus.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Option(name: .long) var mode: String?
    @Option(name: .long) var sourceID: String?
    @Option(name: .long) var displayFilter: String?
    @Option(name: .long) var wiresharkFilter: String?
    @Option(name: .long, help: "JSON object with operator and up to five filters.") var structuredFilterJSON: String?
    @Option(name: .long, help: "Repeat to select multiple quick filters.") var quickFilter: [String] = []
    @Flag(name: .long) var clearQuickFilters = false
    @Option(name: .long) var packetID: String?
    @Flag(name: .long) var clearPacket = false
    @Option(name: .long) var endpointGroup: String?
    @Option(name: .long) var endpointKey: String?
    @Flag(name: .long, help: "Clear the endpoint drill-down selection.") var clearEndpoint = false

    func validate() throws {
        if let mode, !["packets", "overview"].contains(mode) { throw ValidationError("--mode must be packets or overview.") }
        if let packetID, UInt64(packetID) == nil { throw ValidationError("--packet-id must be an unsigned decimal integer.") }
        if packetID != nil && clearPacket { throw ValidationError("Choose --packet-id or --clear-packet.") }
        if !quickFilter.isEmpty && clearQuickFilters { throw ValidationError("Choose --quick-filter or --clear-quick-filters.") }
        if wiresharkFilter != nil && structuredFilterJSON != nil { throw ValidationError("Choose --wireshark-filter or --structured-filter-json.") }
        if (endpointGroup == nil) != (endpointKey == nil) { throw ValidationError("Endpoint selection requires both --endpoint-group and --endpoint-key.") }
        if clearEndpoint && endpointGroup != nil { throw ValidationError("Choose an endpoint or --clear-endpoint.") }
        if let structuredFilterJSON { _ = try structuredValue(structuredFilterJSON) }
    }

    private func structuredValue(_ json: String) throws -> TCPViewerCLIValue {
        guard json.utf8.count <= 32768, let value = try? JSONDecoder().decode(TCPViewerCLIValue.self, from: Data(json.utf8)),
              let object = value.objectValue, let filters = object["filters"]?.arrayValue, filters.count <= 5 else {
            throw ValidationError("--structured-filter-json requires a JSON object with at most five filters.")
        }
        return value
    }

    func run() throws {
        var params: [String: TCPViewerCLIValue] = [:]
        for (key, value) in [("mode", mode), ("source_id", sourceID), ("display_filter", displayFilter), ("wireshark_filter", wiresharkFilter), ("packet_id", packetID)] {
            if let value { params[key] = .string(value) }
        }
        if let structuredFilterJSON { params["structured_filter"] = try structuredValue(structuredFilterJSON) }
        if clearQuickFilters || !quickFilter.isEmpty { params["quick_filters"] = .array(quickFilter.map(TCPViewerCLIValue.string)) }
        if clearPacket { params["packet_id"] = .null }
        if clearEndpoint { params["endpoint"] = .null }
        if let endpointGroup, let endpointKey { params["endpoint"] = .object(["group": .string(endpointGroup), "key": .string(endpointKey)]) }
        try execute(.paneUpdate, params: params, defaultTimeout: 120)
    }
}
struct SplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "split", abstract: "Enable or disable a tab's second pane.", subcommands: [SplitSetCommand.self])
}
enum SplitEnabled: String, ExpressibleByArgument { case on, off }
struct SplitSetCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set split view to on or off.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument var enabled: SplitEnabled
    func run() throws { try execute(.splitSet, params: ["enabled": .bool(enabled == .on)]) }
}
struct SourcesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sources", abstract: "Discover pane source selections.", subcommands: [SourcesListCommand.self])
}
struct SourcesListCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List source IDs for apps, domains, imported files, and other sidebar selections.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Option(name: .long) var offset = 0
    @Option(name: .long) var limit = 50
    func validate() throws { if offset < 0 || !(1...500).contains(limit) { throw ValidationError("offset must be nonnegative and limit must be 1...500.") } }
    func run() throws { try execute(.sourcesList, params: ["offset": .int(offset), "limit": .int(limit)], defaultTimeout: 120) }
}
struct OverviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "overview", abstract: "Read capture dashboard statistics.", subcommands: [OverviewGetCommand.self])
}
struct OverviewGetCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read totals, protocols, top apps and destinations, and timeline data.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.overviewGet, defaultTimeout: 120) }
}
struct StatisticsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "statistics", abstract: "Read capture analysis data.", subcommands: [StatisticsEndpointsCommand.self])
}
struct StatisticsEndpointsCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "endpoints", abstract: "Read endpoint groups with search, sorting, and pagination.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Option(name: .long) var group = "apps"
    @Option(name: .long) var search = ""
    @Option(name: .long) var sort = "bytes"
    @Option(name: .long) var order = "desc"
    @Option(name: .long) var offset = 0
    @Option(name: .long) var limit = 50
    func validate() throws {
        guard ["apps", "domains", "ipv4", "ipv6", "tcp", "udp"].contains(group), ["asc", "desc"].contains(order),
              offset >= 0, (1...500).contains(limit) else { throw ValidationError("Invalid group, order, offset, or limit. See --help.") }
    }
    func run() throws {
        try execute(.statisticsEndpoints, params: ["group": .string(group), "search": .string(search), "sort": .string(sort),
                                                  "order": .string(order), "offset": .int(offset), "limit": .int(limit)], defaultTimeout: 120)
    }
}
