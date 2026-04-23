import SwiftUI
import PcapPlusPlusCore

struct CaptureInterfaceToolbarView: View {
    let interfaces: [CaptureInterfaceSummary]
    let selectedInterfaceID: String?
    let isLocked: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            if interfaces.isEmpty {
                Text("No Interfaces")
            } else {
                ForEach(interfaces) { interface in
                    Button {
                        onSelect(interface.id)
                    } label: {
                        Label(interfaceTitle(interface), systemImage: interface.id == selectedInterfaceID ? "checkmark" : "network")
                    }
                    .disabled(!interface.isSelectable || isLocked)
                    .help(interfaceHelp(interface))
                }
            }
        } label: {
            Label(selectedInterfaceTitle, systemImage: "network")
                .lineLimit(1)
        }
        .disabled(interfaces.isEmpty || isLocked)
        .help(isLocked ? "Stop capture before changing interfaces" : "Capture interface")
        .packetryToolbarButtonStyle()
    }

    private var selectedInterfaceTitle: String {
        guard let selectedInterface = interfaces.first(where: { $0.id == selectedInterfaceID }) else {
            return "Interface"
        }

        return interfaceTitle(selectedInterface)
    }

    private func interfaceTitle(_ interface: CaptureInterfaceSummary) -> String {
        interface.friendlyName ?? interface.displayName
    }

    private func interfaceHelp(_ interface: CaptureInterfaceSummary) -> String {
        if let reason = interface.availabilityReason, !interface.isSelectable {
            return reason
        }

        return interface.technicalName
    }
}
