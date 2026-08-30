//
//  FileLicenseSettingsCommands.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import ArgumentParser
import Darwin
import Foundation

struct FileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "file",
        abstract: "Import and export capture files.",
        subcommands: [FileImportCommand.self, FileExportCommand.self, FileExportSessionCommand.self]
    )
}

struct FileImportCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Import pcap, pcapng, or one tcpviewsession file.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "Capture file paths.") var paths: [String]

    func validate() throws {
        guard !paths.isEmpty, paths.count <= 100 else {
            throw ValidationError("file import requires between 1 and 100 paths.")
        }
        let extensions = paths.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
        guard extensions.allSatisfy({ ["pcap", "pcapng", "tcpviewsession"].contains($0) }) else {
            throw ValidationError("file import accepts only pcap, pcapng, and tcpviewsession files.")
        }
        if extensions.contains("tcpviewsession") && paths.count != 1 {
            throw ValidationError("A tcpviewsession must be imported by itself.")
        }
    }

    func run() throws {
        let absolutePaths = paths.map(TCPViewerCLIPath.absolute)
        try execute(.fileImport, params: [
            "paths": .array(absolutePaths.map(TCPViewerCLIValue.string)),
        ], defaultTimeout: 300)
    }
}

enum FileExportFormat: String, ExpressibleByArgument {
    case pcap
    case pcapng
}

struct FileExportCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export selected packets to pcap or pcapng.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "Destination path.") var path: String
    @Option(name: .long) var format: FileExportFormat
    @Flag(name: .long, help: "Export the bounded scan when no selectors are supplied.") var all = false
    @Flag(name: .long, help: "Replace an existing regular file.") var overwrite = false
    @OptionGroup var query: TCPViewerCLIPacketQueryOptions

    func validate() throws {
        try query.validate()
        guard all || query.hasSelector else {
            throw ValidationError("file export requires --all or at least one packet selector.")
        }
        guard !(all && query.hasSelector) else {
            throw ValidationError("file export accepts --all or packet selectors, but not both.")
        }
    }

    func run() throws {
        var params = try query.params()
        params["path"] = .string(TCPViewerCLIPath.absolute(path))
        params["format"] = .string(format.rawValue)
        params["all"] = .bool(all)
        params["overwrite"] = .bool(overwrite)
        try execute(.fileExport, params: params, defaultTimeout: 300)
    }
}

struct FileExportSessionCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "export-session", abstract: "Export the active TCP Viewer session.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument(help: "Destination tcpviewsession path.") var path: String
    @Flag(name: .long, help: "Replace an existing regular file.") var overwrite = false

    func run() throws {
        try execute(.fileExportSession, params: [
            "path": .string(TCPViewerCLIPath.absolute(path)),
            "overwrite": .bool(overwrite),
        ], defaultTimeout: 300)
    }
}

struct LicenseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "license",
        abstract: "Manage the TCP Viewer license.",
        subcommands: [LicenseStatusCommand.self, LicenseActivateCommand.self, LicenseRevokeCommand.self]
    )
}

struct LicenseStatusCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show license status without exposing the receipt.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.licenseStatus, defaultTimeout: 60) }
}

struct LicenseActivateCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "activate", abstract: "Activate a license key read from stdin or a secure prompt.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions

    func run() throws {
        let key = try TCPViewerCLILicenseKeyReader.read()
        try execute(.licenseActivate, params: ["license_key": .string(key)], defaultTimeout: 60)
    }
}

struct LicenseRevokeCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "revoke", abstract: "Revoke this Mac's license seat.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Flag(name: .long, help: "Confirm license revocation.") var yes = false
    func validate() throws { if !yes { throw ValidationError("license revoke requires --yes.") } }
    func run() throws { try execute(.licenseRevoke, params: ["confirm": .bool(true)], defaultTimeout: 60) }
}

struct SettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Read and change TCP Viewer settings.",
        subcommands: [SettingsListCommand.self, SettingsGetCommand.self, SettingsSetCommand.self, SettingsResetCommand.self]
    )
}

struct SettingsListCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List supported settings and current values.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.settingsList) }
}

struct SettingsGetCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read one setting.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument var key: String
    func run() throws { try execute(.settingsGet, params: ["key": .string(key)]) }
}

struct SettingsSetCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change one setting.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument var key: String
    @Argument var value: String
    func run() throws { try execute(.settingsSet, params: ["key": .string(key), "value": .string(value)]) }
}

struct SettingsResetCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Reset one setting or every supported setting.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    @Argument var key: String?
    @Flag(name: .long, help: "Reset every supported setting.") var all = false
    @Flag(name: .long, help: "Confirm resetting all supported settings.") var yes = false

    func validate() throws {
        guard (key != nil) != all else {
            throw ValidationError("Provide one setting key or --all.")
        }
        if all && !yes {
            throw ValidationError("settings reset --all requires --yes.")
        }
    }

    func run() throws {
        var params: [String: TCPViewerCLIValue] = ["all": .bool(all)]
        if let key { params["key"] = .string(key) }
        try execute(.settingsReset, params: params)
    }
}

enum TCPViewerCLIPath {
    static func absolute(_ path: String) -> String {
        let baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL.path
    }
}

enum TCPViewerCLILicenseKeyReader {
    static func read() throws -> String {
        let value: String
        if isatty(STDIN_FILENO) == 1 {
            guard let pointer = getpass("License key: ") else {
                throw ValidationError("Could not read the license key.")
            }
            value = String(cString: pointer)
        } else {
            value = readLine() ?? ""
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("TCPV-") else {
            throw ValidationError("A TCP Viewer license key must start with TCPV-.")
        }
        return normalized
    }
}
