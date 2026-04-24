import SwiftUI

struct ContentView: View {
    private let services: PacketryServiceRegistry

    @MainActor
    init() {
        self.init(services: .foundation)
    }

    init(services: PacketryServiceRegistry) {
        self.services = services
    }

    var body: some View {
        NetworkInspectorWindow(services: services)
    }
}
