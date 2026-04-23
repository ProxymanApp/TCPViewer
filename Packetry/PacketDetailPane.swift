import SwiftUI
import PcapPlusPlusCore

struct PacketDetailPane: View {
    @ObservedObject var controller: PacketryWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader

            if controller.snapshot.inspectionState.isLoading {
                ProgressView("Decoding selected packet…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let inspection = controller.snapshot.inspectionState.inspection {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(inspection.detailNodes) { node in
                            PacketDetailNodeRow(
                                node: node,
                                depth: 0,
                                selectedNodeID: controller.snapshot.inspectionState.selectedDetailNodeID,
                                onSelect: { controller.selectDetailNode($0) }
                            )
                        }
                    }
                    .padding(12)
                }
            } else {
                ContentUnavailableView(
                    "Decode Tree",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(controller.snapshot.inspectionState.statusMessage)
                )
            }
        }
        .background(.regularMaterial)
    }

    private var paneHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Packet Details")
                .font(.headline)

            if let inspection = controller.snapshot.inspectionState.inspection {
                Text("Packet \(inspection.packetNumber) • \(inspection.decodeStatus.kind.rawValue.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(controller.snapshot.inspectionState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct PacketDetailNodeRow: View {
    let node: PacketDetailNode
    let depth: Int
    let selectedNodeID: String?
    let onSelect: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                onSelect(node.id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(spacing: 6) {
                        if !node.children.isEmpty {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: node.kind == .warning ? "exclamationmark.triangle.fill" : "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(node.kind == .warning ? .orange : .secondary)
                        }

                        Text(node.name)
                            .fontWeight(node.kind == .layer ? .semibold : .regular)
                            .foregroundStyle(node.kind == .warning ? .orange : .primary)
                    }

                    Spacer(minLength: 12)

                    if let value = node.value {
                        Text(value)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, CGFloat(depth) * 18)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedNodeID == node.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            ForEach(node.children) { child in
                PacketDetailNodeRow(
                    node: child,
                    depth: depth + 1,
                    selectedNodeID: selectedNodeID,
                    onSelect: onSelect
                )
            }
        }
    }
}
