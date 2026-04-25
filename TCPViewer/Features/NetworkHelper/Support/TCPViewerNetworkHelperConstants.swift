import Darwin

enum TCPViewerNetworkHelperConstants {
    static let displayName = "TCP Viewer Network Helper Tool"
    static let serviceLabel = "com.proxyman.tcpviewer.helpertool"
    static let launchDaemonPlistName = "\(serviceLabel).plist"
    static let legacyServiceLabels = [
        "com.proxyman.Packetry.NetworkHelper",
        "com.proxyman.Packetman.NetworkHelper",
    ]
    static let legacyLaunchDaemonPlistNames = legacyServiceLabels.map { "\($0).plist" }
    static let captureGroupName = "tcpviewer_capture"
    static let bpfDeviceDirectory = "/dev"
    static let bpfDeviceMode: mode_t = 0o660
}
