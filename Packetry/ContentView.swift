//
//  ContentView.swift
//  Packetry
//
//  Created by nghiatran on 23/4/26.
//

import SwiftUI
import PcapPlusPlusCore

struct ContentView: View {
    @StateObject private var controller: PacketryWindowController

    init(services: PacketryServiceRegistry = .foundation) {
        _controller = StateObject(wrappedValue: PacketryWindowController(services: services))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Packetry v0.1 Foundation")
                .font(.title2.weight(.semibold))

            Text("The app is now wired around window-scoped foundation state instead of the default template UI.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                stateRow("Capture Access", controller.snapshot.accessState.title)
                stateRow("Document", controller.snapshot.documentState.phase.rawValue.capitalized)
                stateRow("Session", controller.snapshot.sessionState.phase.rawValue.capitalized)
                stateRow("Visible Packets", "\(controller.snapshot.visiblePacketCount)")
                stateRow("Native Core Pin", PcapPlusPlusCoreModule.pinnedTag)
            }
            .padding(16)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))

            Text(controller.snapshot.accessState.detail)
                .font(.callout)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    @ViewBuilder
    private func stateRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    ContentView()
}
