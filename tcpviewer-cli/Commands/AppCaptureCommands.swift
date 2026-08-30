//
//  AppCaptureCommands.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import ArgumentParser
import Foundation

struct AppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Inspect TCP Viewer.",
        subcommands: [AppStatusCommand.self]
    )
}

struct AppStatusCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show TCP Viewer status.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions

    func run() throws {
        try execute(.appStatus, launchIfNeeded: false)
    }
}

struct InterfacesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interfaces",
        abstract: "Inspect capture interfaces.",
        subcommands: [InterfacesListCommand.self]
    )
}

struct InterfacesListCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List capture interfaces.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions

    func run() throws {
        try execute(.interfacesList)
    }
}

struct CaptureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Control live capture.",
        subcommands: [
            CaptureStatusCommand.self,
            CaptureStartCommand.self,
            CapturePauseCommand.self,
            CaptureResumeCommand.self,
            CaptureStopCommand.self,
        ]
    )
}

struct CaptureStatusCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show capture status.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions

    func run() throws {
        try execute(.captureStatus)
    }
}

struct CaptureStartCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start a new live capture.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions

    @Option(name: .long, help: "Capture interface ID from interfaces list.")
    var interface: String

    @Option(name: .long, help: "Persistent libpcap BPF filter for future packets.")
    var bpf: String?

    func validate() throws {
        if interface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || interface.utf8.count > 256 {
            throw ValidationError("--interface must contain between 1 and 256 UTF-8 bytes.")
        }
        if let bpf, bpf.utf8.count > 4_096 {
            throw ValidationError("--bpf cannot exceed 4096 UTF-8 bytes.")
        }
    }

    func run() throws {
        var params: [String: TCPViewerCLIValue] = [:]
        params["interface_id"] = .string(interface)
        if let bpf { params["capture_filter"] = .string(bpf) }
        try execute(.captureStart, params: params)
    }
}

struct CapturePauseCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause live capture.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.capturePause) }
}

struct CaptureResumeCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume paused capture.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.captureResume) }
}

struct CaptureStopCommand: ParsableCommand, TCPViewerCLIRequestCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop live capture.")
    @OptionGroup var global: TCPViewerCLIGlobalOptions
    func run() throws { try execute(.captureStop) }
}
