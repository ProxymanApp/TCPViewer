import Foundation

let result = TCPViewerNetworkHelperCore(system: TCPViewerNetworkHelperPOSIXSystem()).run()

if !result.message.isEmpty {
    FileHandle.standardError.write(Data((result.message + "\n").utf8))
}

exit(result.exitCode.rawValue)
