import SwiftUI
import PcapPlusPlusCore

struct CaptureFilterToolbarView: View {
    @Binding var text: String

    let validation: CaptureFilterValidation
    let isValidating: Bool
    let recentFilters: [String]
    let onSubmit: () -> Void
    let onPickRecent: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("Capture Filter", systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("tcp port 443", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(onSubmit)

            statusIcon

            if !recentFilters.isEmpty {
                Menu {
                    ForEach(recentFilters, id: \.self) { filter in
                        Button(filter) {
                            onPickRecent(filter)
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .help("Recent capture filters")
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isValidating {
            ProgressView()
                .controlSize(.small)
        } else {
            switch validation.disposition {
            case .valid:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .invalid:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .unavailable:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            @unknown default:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
