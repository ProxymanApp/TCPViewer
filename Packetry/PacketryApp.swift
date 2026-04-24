//
//  PacketryApp.swift
//  Packetry
//
//  Created by nghiatran on 23/4/26.
//

import AppKit
import PcapPlusPlusCore
import SwiftUI

@main
struct PacketryApp: App {
    @NSApplicationDelegateAdaptor(PacketryApplicationDelegate.self) private var appDelegate
    @StateObject private var networkHelperToolManager = PacketryNetworkHelperToolManager()

    var body: some Scene {
        WindowGroup {
            ContentView(
                services: PacketryServiceRegistry(
                    core: NativePacketryCore(),
                    networkHelperTool: networkHelperToolManager
                )
            )
        }

        Settings {
            PacketrySettingsView(networkHelperToolManager: networkHelperToolManager)
        }
    }
}

@MainActor
private final class PacketryApplicationDelegate: NSObject, NSApplicationDelegate {
    private var isHandlingTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isHandlingTermination else {
            return .terminateLater
        }

        isHandlingTermination = true
        Task { @MainActor in
            let shouldTerminate = await PacketryWindowController.prepareAllForApplicationTermination()
            isHandlingTermination = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }

        return .terminateLater
    }
}
