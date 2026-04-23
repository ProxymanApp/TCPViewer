import SwiftUI
import PcapPlusPlusCore

struct AnalyzerWorkspaceView: View {
    @ObservedObject var controller: PacketryWindowController

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                PacketTablePane(controller: controller)
                    .frame(minHeight: 280, idealHeight: 380)

                PacketDetailPane(controller: controller)
                    .frame(minHeight: 180, idealHeight: 240)

                PacketBytesPane(controller: controller)
                    .frame(minHeight: 200, idealHeight: 240)
            }
            .background(SplitViewAutosaveConfigurator(name: controller.snapshot.layoutState.verticalAutosaveName))

            Divider()
            AnalyzerStatusStripView(controller: controller)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task {
                        await controller.refreshInterfaces()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .packetryToolbarButtonStyle()

                Button {
                    controller.presentOpenCapturePanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .packetryToolbarButtonStyle()

                Button {
                    Task {
                        await controller.reopenDocument()
                    }
                } label: {
                    Label("Reopen", systemImage: "arrow.clockwise.circle")
                }
                .disabled(!controller.snapshot.documentState.canReopen)
                .packetryToolbarButtonStyle()
            }

            ToolbarItemGroup(placement: .principal) {
                CaptureFilterToolbarView(
                    text: Binding(
                        get: { controller.snapshot.filterState.captureFilterText },
                        set: { controller.updateCaptureFilterText($0) }
                    ),
                    validation: controller.snapshot.filterState.validation,
                    isValidating: controller.snapshot.filterState.isValidating,
                    recentFilters: controller.snapshot.filterState.recentCaptureFilters,
                    onSubmit: {
                        Task {
                            await controller.validateCaptureFilter()
                        }
                    },
                    onPickRecent: { controller.applyRecentCaptureFilter($0) }
                )
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    controller.selectPreviousPacket()
                } label: {
                    Label("Previous Packet", systemImage: "chevron.up")
                }
                .disabled(!canSelectPreviousPacket)
                .packetryToolbarButtonStyle()

                Button {
                    controller.selectNextPacket()
                } label: {
                    Label("Next Packet", systemImage: "chevron.down")
                }
                .disabled(!canSelectNextPacket)
                .packetryToolbarButtonStyle()

                TextField(
                    "Go To #",
                    text: Binding(
                        get: { controller.snapshot.navigationState.jumpText },
                        set: { controller.updateJumpText($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onSubmit {
                    controller.jumpToPacketNumber()
                }

                Button("Go") {
                    controller.jumpToPacketNumber()
                }
                .packetryToolbarButtonStyle()

                Button {
                    Task {
                        await controller.saveDocument()
                    }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!controller.snapshot.documentState.canSave)
                .packetryToolbarButtonStyle()

                Menu {
                    Button("Save As pcap") {
                        controller.presentSaveCapturePanel(format: .pcap)
                    }
                    .disabled(!controller.snapshot.documentState.canSaveAs)

                    Button("Save As pcapng") {
                        controller.presentSaveCapturePanel(format: .pcapng)
                    }
                    .disabled(!controller.snapshot.documentState.canSaveAs)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .packetryToolbarButtonStyle()

                if controller.snapshot.sessionState.canPause {
                    Button {
                        Task {
                            await controller.pauseLiveCapture()
                        }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .packetryToolbarButtonStyle()
                }

                if controller.snapshot.sessionState.canResume {
                    Button {
                        Task {
                            await controller.resumeLiveCapture()
                        }
                    } label: {
                        Label("Resume", systemImage: "playpause.fill")
                    }
                    .packetryToolbarButtonStyle()
                }

                Group {
                    if controller.snapshot.sessionState.canStop {
                        Button {
                            Task {
                                await controller.stopLiveCapture()
                            }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            Task {
                                await controller.startLiveCapture()
                            }
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                    }
                }
                .disabled(!controller.snapshot.sessionState.canStart && !controller.snapshot.sessionState.canStop)
                .packetryToolbarButtonStyle(prominent: true)
            }
        }
    }

    private var canSelectPreviousPacket: Bool {
        guard let selectedPacketID = controller.snapshot.selectedPacketID,
              let selectedIndex = controller.snapshot.navigationState.visiblePackets.firstIndex(where: { $0.id == selectedPacketID }) else {
            return false
        }

        return selectedIndex > 0
    }

    private var canSelectNextPacket: Bool {
        guard let selectedPacketID = controller.snapshot.selectedPacketID,
              let selectedIndex = controller.snapshot.navigationState.visiblePackets.firstIndex(where: { $0.id == selectedPacketID }) else {
            return false
        }

        return selectedIndex < controller.snapshot.navigationState.visiblePackets.count - 1
    }
}
