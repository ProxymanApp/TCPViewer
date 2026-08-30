//
//  TCPViewerCLI.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import ArgumentParser
import Darwin
import Foundation

enum TCPViewerCLIOutputFormat: String, ExpressibleByArgument {
    case json
    case text
}

struct TCPViewerCLIGlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Output format.")
    var output: TCPViewerCLIOutputFormat = .json

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var pretty = false

    @Option(name: .long, help: "Maximum seconds to wait for TCP Viewer.")
    var timeout: Int?

    func validate() throws {
        if pretty && output == .text {
            throw ValidationError("--pretty can only be used with --output json.")
        }
    }

    func resolvedTimeout(default defaultValue: Int) throws -> TimeInterval {
        let value = timeout ?? defaultValue
        guard (1...3_600).contains(value) else {
            throw ValidationError("--timeout must be between 1 and 3600 seconds.")
        }
        return TimeInterval(value)
    }
}

struct TCPViewerCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tcpviewer-cli",
        abstract: "Control TCP Viewer from the command line.",
        version: TCPViewerCLIVersion.current,
        subcommands: [
            AppCommand.self,
            InterfacesCommand.self,
            CaptureCommand.self,
            PacketsCommand.self,
            StreamCommand.self,
            FileCommand.self,
            LicenseCommand.self,
            SettingsCommand.self,
        ]
    )

    // Keep ArgumentParser's messages while using the CLI's documented exit-code contract.
    static func main(_ arguments: [String]? = nil) {
        do {
            var command = try parseAsRoot(arguments)
            try command.run()
        } catch let exitCode as ExitCode {
            Darwin.exit(exitCode.rawValue)
        } catch {
            let message = fullMessage(for: error)
            let isCleanExit = !message.hasPrefix("Error:")
            if !message.isEmpty {
                let handle = isCleanExit ? FileHandle.standardOutput : FileHandle.standardError
                handle.write(Data(message.utf8))
                handle.write(Data("\n".utf8))
            }
            Darwin.exit(isCleanExit ? 0 : 2)
        }
    }

    static func main() {
        main(nil)
    }
}

enum TCPViewerCLIVersion {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.12.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "36"
    }

    static var current: String {
        return "\(version) (\(build))"
    }
}

protocol TCPViewerCLIRequestCommand {
    var global: TCPViewerCLIGlobalOptions { get }
}

extension TCPViewerCLIRequestCommand {
    func execute(
        _ command: TCPViewerCLICommand,
        params: [String: TCPViewerCLIValue] = [:],
        defaultTimeout: Int = 30,
        launchIfNeeded: Bool = true
    ) throws {
        let timeout = try global.resolvedTimeout(default: defaultTimeout)
        let runner = TCPViewerCLIEnvironment.current.runner
        let response: TCPViewerCLIResponse
        do {
            response = try runner.run(
                command: command,
                params: params,
                timeout: timeout,
                launchIfNeeded: launchIfNeeded
            )
        } catch {
            let requestFailure = error as? TCPViewerCLIRequestFailure
            let failure = TCPViewerCLIResponse.failure(
                requestID: requestFailure?.requestID ?? UUID().uuidString.lowercased(),
                command: command,
                code: TCPViewerCLIErrorCode.code(for: error),
                message: error.localizedDescription
            )
            TCPViewerCLIOutput.write(failure, format: global.output, pretty: global.pretty, toStandardError: true)
            throw ExitCode(3)
        }

        TCPViewerCLIOutput.write(response, format: global.output, pretty: global.pretty, toStandardError: !response.ok)
        if !response.ok {
            throw ExitCode(4)
        }
    }
}

enum TCPViewerCLIOutput {
    static func write(
        _ response: TCPViewerCLIResponse,
        format: TCPViewerCLIOutputFormat,
        pretty: Bool,
        toStandardError: Bool
    ) {
        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            data = (try? encoder.encode(response)) ?? Data()
        case .text:
            let text: String
            if response.ok {
                text = humanReadable(response.data ?? [:])
            } else {
                text = response.error?.message ?? "TCP Viewer command failed."
            }
            data = Data(text.utf8)
        }

        let handle = toStandardError ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    private static func humanReadable(_ values: [String: TCPViewerCLIValue]) -> String {
        values.keys.sorted().map { key in
            "\(key): \(text(values[key] ?? .null))"
        }.joined(separator: "\n")
    }

    private static func text(_ value: TCPViewerCLIValue) -> String {
        switch value {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
}

enum TCPViewerCLIErrorCode {
    static func code(for error: Error) -> String {
        switch error {
        case let failure as TCPViewerCLIRequestFailure:
            return failure.code
        case TCPViewerCLIClientError.appNotFound:
            return "app_not_found"
        case TCPViewerCLIClientError.launchFailed:
            return "launch_failed"
        case TCPViewerCLIClientError.timeout:
            return "timeout"
        case is TCPViewerCLIFileStoreError:
            return "transport_error"
        default:
            return "transport_error"
        }
    }
}

final class TCPViewerCLIEnvironment {
    static var current = TCPViewerCLIEnvironment()

    let runner: TCPViewerCLIRequestRunning

    init(runner: TCPViewerCLIRequestRunning = TCPViewerCLIClient()) {
        self.runner = runner
    }
}
