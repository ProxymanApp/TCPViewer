import Foundation

let result = PacketryNetworkHelperCore(system: PacketryNetworkHelperPOSIXSystem()).run()

if !result.message.isEmpty {
    FileHandle.standardError.write(Data((result.message + "\n").utf8))
}

exit(result.exitCode.rawValue)
