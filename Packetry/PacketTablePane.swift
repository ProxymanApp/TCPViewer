import SwiftUI
import PcapPlusPlusCore

struct PacketTablePane: View {
    @ObservedObject var controller: PacketryWindowController

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader

            Table(controller.snapshot.navigationState.visiblePackets, selection: selectionBinding) {
                TableColumn("No.") { packet in
                    Text("\(packet.packetNumber)")
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 56, ideal: 72, max: 92)

                TableColumn("Time") { packet in
                    Text(Self.timestampFormatter.string(from: packet.timestamp))
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 120, ideal: 140, max: 170)

                TableColumn("Source") { packet in
                    Text(endpointLabel(packet.endpoints.source))
                        .lineLimit(1)
                }
                .width(min: 160, ideal: 200)

                TableColumn("Destination") { packet in
                    Text(endpointLabel(packet.endpoints.destination))
                        .lineLimit(1)
                }
                .width(min: 160, ideal: 200)

                TableColumn("Protocol") { packet in
                    Text(Self.protocolLabel(for: packet))
                        .fontWeight(packet.decodeStatus.kind == .complete ? .regular : .semibold)
                }
                .width(min: 84, ideal: 100, max: 120)

                TableColumn("Length") { packet in
                    Text("\(packet.capturedLength)")
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 68, ideal: 80, max: 96)

                TableColumn("Info") { packet in
                    Text(packet.infoSummary)
                        .lineLimit(1)
                        .foregroundStyle(packet.decodeStatus.kind == .complete ? Color.primary : Color.orange)
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
        .background(.regularMaterial)
    }

    private var paneHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Packet List")
                    .font(.headline)
                Text(controller.snapshot.navigationState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(controller.snapshot.navigationState.visiblePackets.count) packets")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var selectionBinding: Binding<PacketSummary.ID?> {
        Binding(
            get: { controller.snapshot.selectedPacketID },
            set: { controller.selectPacket($0) }
        )
    }

    private func endpointLabel(_ endpoint: PacketEndpoint) -> String {
        guard let address = endpoint.address else {
            return "—"
        }

        if let port = endpoint.port {
            return "\(address):\(port)"
        }

        return address
    }

    static func protocolLabel(for packet: PacketSummary) -> String {
        if packet.transportHint != .unknown {
            return packet.transportHint.rawValue.uppercased()
        }

        if let lastLayer = packet.layers.last?.name, !lastLayer.isEmpty {
            return lastLayer
        }

        return packet.transportHint.rawValue.uppercased()
    }
}
