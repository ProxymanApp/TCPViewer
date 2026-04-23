import SwiftUI
import PcapPlusPlusCore

struct PacketBytesPane: View {
    @ObservedObject var controller: PacketryWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader

            if let inspection = controller.snapshot.inspectionState.inspection {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(hexRows(for: inspection.rawBytes)) { row in
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(format: "%04X", row.offset))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .leading)

                                HStack(spacing: 4) {
                                    ForEach(0..<16, id: \.self) { column in
                                        if let byte = row.byte(at: column) {
                                            Text(String(format: "%02X", byte))
                                                .foregroundStyle(isHighlighted(row.offset + column) ? .primary : .secondary)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(isHighlighted(row.offset + column) ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                        } else {
                                            Text("  ")
                                                .foregroundStyle(.clear)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                        }
                                    }
                                }
                                .frame(maxWidth: 520, alignment: .leading)

                                Text(row.ascii)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(.body, design: .monospaced))
                        }
                    }
                    .padding(12)
                }
            } else {
                ContentUnavailableView(
                    "Raw Bytes",
                    systemImage: "binary",
                    description: Text("Select a packet to inspect its byte ranges.")
                )
            }
        }
        .background(.regularMaterial)
    }

    private var paneHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Packet Bytes")
                    .font(.headline)

                if let highlightedRange = controller.snapshot.inspectionState.highlightedByteRange {
                    Text("Highlighting bytes \(highlightedRange.offset)–\(highlightedRange.upperBound - 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a field in the decode tree to highlight its byte range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let inspection = controller.snapshot.inspectionState.inspection {
                Text("\(inspection.rawBytes.count) bytes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func isHighlighted(_ offset: Int) -> Bool {
        guard let range = controller.snapshot.inspectionState.highlightedByteRange else {
            return false
        }

        return offset >= range.offset && offset < range.upperBound
    }

    private func hexRows(for data: Data) -> [HexDumpRow] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let chunk = Array(bytes[offset..<min(offset + 16, bytes.count)])
            return HexDumpRow(offset: offset, bytes: chunk)
        }
    }
}

private struct HexDumpRow: Identifiable {
    let offset: Int
    let bytes: [UInt8]

    var id: Int { offset }

    func byte(at index: Int) -> UInt8? {
        guard bytes.indices.contains(index) else {
            return nil
        }

        return bytes[index]
    }

    var ascii: String {
        String(bytes.map { byte in
            switch byte {
            case 32...126:
                Character(UnicodeScalar(byte))
            default:
                "."
            }
        })
    }
}
