import SwiftUI

struct ContentView: View {
    @StateObject private var controller: PacketryWindowController

    init(services: PacketryServiceRegistry = .foundation) {
        _controller = StateObject(wrappedValue: PacketryWindowController(services: services))
    }

    var body: some View {
        AnalyzerWorkspaceView(controller: controller)
            .frame(minWidth: 1_140, minHeight: 820)
            .task {
                await controller.performInitialLoadIfNeeded()
            }
    }
}
