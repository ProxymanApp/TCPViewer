import SwiftUI
import PcapPlusPlusCore

struct AnalyzerStatusStripView: View {
    @ObservedObject var controller: PacketryWindowController

    var body: some View {
        HStack(spacing: 16) {
            Label(controller.snapshot.accessState.title, systemImage: accessImageName)
                .foregroundStyle(controller.snapshot.accessState.isCaptureReady ? .green : .secondary)

            Text(controller.snapshot.sessionState.phase.rawValue.capitalized)
                .foregroundStyle(.secondary)

            Text(controller.snapshot.documentState.phase.rawValue.capitalized)
                .foregroundStyle(.secondary)

            if controller.snapshot.loadState.progress.phase == .loading {
                ProgressView(value: controller.snapshot.loadState.progress.fractionCompleted ?? 0)
                    .frame(width: 140)
                Text(controller.snapshot.loadState.progress.message)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else if controller.snapshot.documentState.isPartialResult {
                Label("Partial Load", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text(controller.snapshot.packetIngestState.statusMessage)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if controller.snapshot.loadState.canCancel {
                Button("Cancel Load") {
                    Task {
                        await controller.cancelDocumentLoading()
                    }
                }
                .packetryToolbarButtonStyle()
            }

            Text("Visible \(controller.snapshot.visiblePacketCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var accessImageName: String {
        switch controller.snapshot.accessState {
        case .ready:
            "checkmark.circle.fill"
        case .blocked:
            "exclamationmark.triangle.fill"
        case .checking, .recovering, .unknown:
            "bolt.horizontal.circle"
        }
    }
}
