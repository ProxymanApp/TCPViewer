import SwiftUI

struct ContentView: View {
    private let services: PacketryServiceRegistry

    init(services: PacketryServiceRegistry = .foundation) {
        self.services = services
    }

    var body: some View {
        NetworkInspectorWindow(services: services)
    }
}
