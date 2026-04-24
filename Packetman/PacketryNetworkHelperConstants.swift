import Darwin

enum PacketryNetworkHelperConstants {
    static let displayName = "Packetry Network Helper Tool"
    static let serviceLabel = "com.proxyman.Packetry.NetworkHelper"
    static let launchDaemonPlistName = "\(serviceLabel).plist"
    static let captureGroupName = "packetry_capture"
    static let bpfDeviceDirectory = "/dev"
    static let bpfDeviceMode: mode_t = 0o660
}
