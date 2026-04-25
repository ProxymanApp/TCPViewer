import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
struct PacketExportServiceTests {

    @Test func defaultNamesIncludeTimestampAndFormat() {
        let defaults = Self.makeDefaults()
        let date = Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 25,
            hour: 14,
            minute: 5,
            second: 6
        ))!
        let service = PacketExportService(defaults: defaults, now: { date })

        #expect(service.defaultFileName(scopeName: "TCPViewer-Session", format: .pcap) == "TCPViewer-Session-20260425-140506.pcap")
        #expect(service.defaultFileName(scopeName: "TCPViewer-Domains", format: .pcapng) == "TCPViewer-Domains-20260425-140506.pcapng")
    }

    @Test func remembersLastExportDirectory() {
        let defaults = Self.makeDefaults()
        let service = PacketExportService(defaults: defaults)
        let destination = URL(fileURLWithPath: "/tmp/TCPViewerExports/session.pcapng")

        service.rememberDestination(destination)

        #expect(service.lastDirectoryURL()?.path == "/tmp/TCPViewerExports")
    }

    private static func makeDefaults() -> UserDefaults {
        let suiteName = "TCPViewer.PacketExportServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
