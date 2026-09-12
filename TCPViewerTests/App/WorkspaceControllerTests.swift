//
//  WorkspaceControllerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import AppKit
import Carbon
import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
@MainActor
struct WindowControllerTests {

    // A suspended source can receive appends followed by summary updates before its next sidebar render.
    @Test(arguments: [false, true])
    func hiddenLivePaneKeepsSidebarPacketsAfterSummaryUpdate(opensNewPane: Bool) async {
        let first = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let second = makePacket(packetNumber: 2, source: .live, transportHint: .udp)
        let live = FakeLiveSession()
        let core = FakeTCPViewerCore(interfaceInventories: [[makeInterface(id: "en0", displayName: "Test")]], liveSession: live)
        let source = TCPViewerCaptureWorkspace(services: .init(core: core))
        let defaults = UserDefaults(suiteName: "tabs-sidebar-\(UUID())")!
        let pane = NetworkInspectorViewModel(services: source.controller.services, captureWorkspace: source, userDefaults: defaults)
        defer { pane.close(); source.close() }
        await pane.performInitialLoadIfNeeded()
        await source.controller.startLiveCapture()
        live.send(.packetBatch([first], disposition: .append))
        await waitUntil { pane.snapshot.totalPacketCount == 1 }
        #expect(pane.snapshot.sourceListSnapshot.item(for: .domain(.ipAddresses))?.count == 1)

        pane.deactivate()
        live.send(.packetBatch([second], disposition: .append))
        await waitUntil { source.controller.snapshot.packetIngestState.totalPacketCount == 2 }
        live.send(.packetSummaryUpdates([PacketSummaryUpdate(packetID: first.id, protocolSummary: "HTTP", infoSummary: "Updated")]))
        await waitUntil { source.controller.snapshot.packetIngestState.packet(withID: first.id)?.infoSummary == "Updated" }
        #expect(pane.snapshot.packetRows.isEmpty)
        #expect(!pane.hasPendingCoalescedRebuildForTesting)

        let activePane = opensNewPane
            ? NetworkInspectorViewModel(services: source.controller.services, captureWorkspace: source, userDefaults: defaults)
            : pane
        defer { activePane.close() }
        activePane.activate()
        #expect(activePane.snapshot.totalPacketCount == 2)
        #expect(activePane.snapshot.sourceListSnapshot.item(for: .domain(.ipAddresses))?.count == 2)
        #expect(core.liveSessionRequests.count == 1)
    }

    // Opening a capture at launch must expose interfaces without constructing a live pane or session.
    @Test func offlineOnlyWindowDiscoversInterfacesOnceWithoutCreatingLivePane() async {
        let core = FakeTCPViewerCore(interfaceInventories: [[makeInterface(id: "en0", displayName: "Test")]], documentFactory: { url in
            FakeOfflineDocument(url: url, metadata: .init(format: .pcapng), openPlan: .completed([]))
        })
        let defaults = UserDefaults(suiteName: "tabs-interfaces-\(UUID())")!
        let owner = TCPViewerWindowController(services: .init(core: core), configuration: AppConfiguration(defaults: defaults),
                                               startsWithLiveTab: false)
        defer { owner.window?.close() }
        #expect(owner.tabs.isEmpty)
        let result = await withCheckedContinuation { continuation in
            owner.importCaptureURLs([URL(fileURLWithPath: "/tmp/tab-cold-import.pcapng")], automaticNewTab: true) {
                continuation.resume(returning: $0)
            }
        }
        #expect(result.error == nil)
        let source = TCPViewerWorkspaceAutomationSource(windowController: owner)
        await waitUntil { source.mcpWorkspaceSnapshot().interfaces.map(\.id) == ["en0"] }
        #expect(source.mcpWorkspaceSnapshot().interfaces.map(\.id) == ["en0"])
        #expect(owner.tabs.count == 1)
        #expect(owner.selectedTab?.isOffline == true)
        #expect(core.liveSessionRequests.isEmpty)
        #expect(core.interfaceCallCount == 1)

        owner.newWorkspaceTab(nil)
        await settleEventLoop()
        #expect(core.interfaceCallCount == 1)
        #expect(core.liveSessionRequests.isEmpty)
    }

    // Transcript navigation must select the stream's original tab before updating its table and inspector.
    @Test(arguments: [2, 5_001])
    func followStreamRevealReactivatesOriginalTab(packetCount: Int) async throws {
        let packets = (1...packetCount).map {
            makePacket(packetNumber: UInt64($0), source: .offline, transportHint: .tcp,
                       followStreamID: .init(streamProtocol: .tcp, streamID: 42))
        }
        let packet = try #require(packets.last)
        let core = FakeTCPViewerCore(interfaceInventories: [[]], documentFactory: { url in
            FakeOfflineDocument(url: url, metadata: .init(format: .pcapng), openPlan: .completed(packets))
        })
        let configuration = AppConfiguration(defaults: UserDefaults(suiteName: "tabs-reveal-\(UUID())")!)
        let owner = TCPViewerWindowController(services: .init(core: core), configuration: configuration)
        defer { owner.window?.close() }
        _ = await withCheckedContinuation { continuation in
            owner.importCaptureURLs([URL(fileURLWithPath: "/tmp/tab-reveal.pcapng")], automaticNewTab: true) {
                continuation.resume(returning: $0)
            }
        }
        let originalID = try #require(owner.selectedTabID)
        let original = owner.rootViewController
        original.viewModel.updateDisplayFilterText("protocol:tcp")
        await waitUntil { !original.viewModel.snapshot.isPacketTableFiltering }
        original.viewModel.selectPacket(packets[0].id)
        original.followSelectedStream()
        let follow = try #require(NSApp.windows.compactMap { $0.windowController as? FollowStreamWindowController }.first)
        owner.newWorkspaceTab(nil)
        let otherID = try #require(owner.selectedTabID)
        // Ordinary tab switching still restores the previous selection before an explicit reveal overrides it.
        owner.selectTab(originalID)
        await waitUntil { !original.viewModel.snapshot.isPacketTableFiltering }
        #expect(original.selectedFollowRow?.id == packets[0].id)
        owner.selectTab(otherID)
        #expect(original.view.window == nil)
        #expect(!original.viewModel.isActive)

        follow.revealPacket?(FollowStreamRevealTarget(packetID: packet.id, payload: Data()))
        #expect(owner.selectedTabID == originalID)
        #expect(original.viewModel.isActive)
        #expect(original.view.window === owner.window)
        await waitUntil {
            !original.viewModel.snapshot.isPacketTableFiltering &&
                original.viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id
        }
        #expect(original.viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id)
        #expect(original.viewModel.snapshot.isInspectorVisible)
        #expect(original.selectedFollowRow?.id == packet.id)

        // Check the viewport after a deferred filter rebuild, not only the model's selected ID.
        func packetTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let table = packetTable(in: child) { return table }
            }
            return nil
        }
        let table = try #require(packetTable(in: original.view))
        #expect(NSIntersectsRect(table.rect(ofRow: packetCount - 1), table.visibleRect))
    }

    @Test func workspaceTabLazilyCreatesAndReleasesItsPaneAcrossFiftyCycles() async {
        let core = FakeTCPViewerCore(interfaceInventories: [[]])
        let source = TCPViewerCaptureWorkspace(services: .init(core: core))
        let defaults = UserDefaults(suiteName: "tabs-lifetime-\(UUID())")!
        let configuration = AppConfiguration(defaults: defaults)
        var factoryCount = 0
        for _ in 0..<50 {
            weak var releasedPane: TCPViewerRootViewController?
            weak var releasedModel: NetworkInspectorViewModel?
            var releasedChildren: [WeakTabTestObject] = []
            autoreleasepool {
                let tab = TCPViewerWorkspaceTab(source: source)
                #expect(tab.pane == nil)
                _ = tab.displayTitle
                #expect(tab.pane == nil)
                let factory: (TCPViewerCaptureWorkspace) -> TCPViewerRootViewController = { source in
                    factoryCount += 1
                    let model = NetworkInspectorViewModel(services: source.controller.services, captureWorkspace: source, userDefaults: defaults)
                    return TCPViewerRootViewController(viewModel: model, configuration: configuration)
                }
                let first = tab.openPane(using: factory)
                #expect(tab.openPane(using: factory) === first)
                first?.loadViewIfNeeded()
                if let first { releasedChildren = weakDescendants(of: first) }
                releasedPane = first
                releasedModel = first?.viewModel
                tab.close()
                tab.close()
                #expect(tab.source == nil)
                #expect(tab.pane == nil)
            }
            await waitUntil { releasedPane == nil && releasedModel == nil }
            #expect(releasedPane == nil)
            #expect(releasedModel == nil)
            await waitUntil { releasedChildren.allSatisfy { $0.object == nil } }
            #expect(releasedChildren.allSatisfy { $0.object == nil })
            #expect(source.subscriberCountForTesting == 0)
        }
        #expect(factoryCount == 50)
        #expect(core.liveSessionRequests.isEmpty)
        let closed = await withCheckedContinuation { continuation in source.close { continuation.resume(returning: $0) } }
        #expect(closed)
        #expect(!source.statusMetricsService.isSampling)
    }

    @Test func splitPaneIsLazyLimitedToTwoAndFullyReleasedAcrossFiftyCycles() async throws {
        let core = FakeTCPViewerCore(interfaceInventories: [[]])
        let source = TCPViewerCaptureWorkspace(services: .init(core: core))
        let defaults = UserDefaults(suiteName: "split-lifetime-\(UUID())")!
        let configuration = AppConfiguration(defaults: defaults)
        let tab = TCPViewerWorkspaceTab(source: source)
        let first = try #require(tab.openPane { source in
            TCPViewerRootViewController(
                viewModel: NetworkInspectorViewModel(
                    services: source.controller.services,
                    captureWorkspace: source,
                    userDefaults: defaults
                ),
                configuration: configuration
            )
        })
        first.loadViewIfNeeded()
        tab.contentController?.loadViewIfNeeded()
        #expect(tab.secondPane == nil)
        #expect(source.subscriberCountForTesting == 1)

        for cycle in 0..<50 {
            weak var releasedPane: TCPViewerRootViewController?
            weak var releasedModel: NetworkInspectorViewModel?
            var releasedHierarchy: [WeakTabTestObject] = []
            autoreleasepool {
                let second = tab.openSecondPane { source, state in
                    TCPViewerRootViewController(
                        viewModel: NetworkInspectorViewModel(
                            services: source.controller.services,
                            captureWorkspace: source,
                            userDefaults: defaults,
                            paneState: state
                        ),
                        configuration: configuration
                    )
                }
                #expect(second != nil)
                #expect(tab.openSecondPane { _, _ in Issue.record("Created a third pane"); return first } === second)
                second?.loadViewIfNeeded()
                tab.contentController?.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 700)
                tab.contentController?.view.layoutSubtreeIfNeeded()
                #expect(tab.contentController?.splitViewForTesting.arrangedSubviews.count == 2)
                #expect(source.subscriberCountForTesting == 2)
                if cycle == 0, let splitView = tab.contentController?.splitViewForTesting {
                    let widths = splitView.arrangedSubviews.map(\.frame.width)
                    #expect(abs(widths[0] - widths[1]) <= 2)
                    #expect(widths.allSatisfy { $0 >= 300 })
                    #expect(splitView.dividerThickness > 0)
                }
                if let second { releasedHierarchy = weakHierarchy(of: second) }
                releasedPane = second
                releasedModel = second?.viewModel
                tab.closeSplitView()
                #expect(tab.secondPane == nil)
                #expect(tab.pane === first)
            }
            await waitUntil {
                releasedPane == nil && releasedModel == nil &&
                    releasedHierarchy.allSatisfy { $0.object == nil }
            }
            #expect(releasedPane == nil)
            #expect(releasedModel == nil)
            let retainedTypes = releasedHierarchy.compactMap(\.typeName)
            #expect(retainedTypes.isEmpty, "Retained split hierarchy: \(retainedTypes)")
            #expect(source.subscriberCountForTesting == 1)
        }

        tab.close()
        #expect(source.subscriberCountForTesting == 0)
        #expect(core.liveSessionRequests.isEmpty)
        source.close()
    }

    // Populated inspectors must not restore the old large window-size floor when panes change.
    @Test(arguments: [false, true], [false, true])
    func mainWindowResizesToCompactContent(opensSplit: Bool, sidebarVisible: Bool) async throws {
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)
        let inspection = makeInspection(for: packet)
        let core = FakeTCPViewerCore(interfaceInventories: [[]], documentFactory: { url in
            FakeOfflineDocument(
                url: url,
                metadata: .init(format: .pcapng),
                openPlan: .completed([packet]),
                inspections: [packet.id: inspection]
            )
        })
        let defaults = UserDefaults(suiteName: "compact-window-\(UUID())")!
        let owner = TCPViewerWindowController(
            services: .init(core: core),
            configuration: AppConfiguration(defaults: defaults),
            startsWithLiveTab: false
        )
        defer { owner.window?.close() }
        let result = await withCheckedContinuation { continuation in
            owner.importCaptureURLs([URL(fileURLWithPath: "/tmp/compact-window.pcapng")], automaticNewTab: true) {
                continuation.resume(returning: $0)
            }
        }
        #expect(result.error == nil)
        let window = try #require(owner.window)
        let first = owner.rootViewController
        first.viewModel.showInspectorForSplitView()
        first.viewModel.selectPacket(packet.id)
        await waitUntil { first.viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id }
        #expect(first.viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id)
        owner.workspaceViewController.setSidebarVisible(sidebarVisible, viewModel: first.viewModel, persistPreference: false)
        if opensSplit { owner.toggleSplitView(nil) }
        await settleEventLoop()

        let compactSize = sidebarVisible ? NSSize(width: 840, height: 450) : NSSize(width: 640, height: 400)
        #expect(window.contentMinSize.width <= compactSize.width)
        #expect(window.contentMinSize.height <= compactSize.height)
        func filterEditor(in controller: NSViewController) -> PacketStructuredFilterViewController? {
            if let editor = controller as? PacketStructuredFilterViewController { return editor }
            return controller.children.compactMap { filterEditor(in: $0) }.first
        }
        let content = try #require(owner.selectedTab?.contentController)
        let quickFilters = try #require(window.titlebarAccessoryViewControllers.first { $0 is PacketQuickFilterViewController })
        let quickFilterScroll = try #require(quickFilters.view.subviews.compactMap { $0 as? NSScrollView }.first)
        for showsFilter in [false, true, false] {
            content.panes.forEach { $0.viewModel.setStructuredFilterVisible(showsFilter) }
            for size in [compactSize, NSSize(width: 1_000, height: 700), compactSize] {
                window.setContentSize(size)
                window.contentView?.layoutSubtreeIfNeeded()
                await settleEventLoop()
                let actualSize = window.contentRect(forFrameRect: window.frame).size
                #expect(actualSize.width == size.width)
                #expect(actualSize.height == size.height)
                #expect(content.view.bounds.width <= actualSize.width + 1)
                #expect(quickFilterScroll.contentView.bounds.width > 0)
                let quickFilterDocument = try #require(quickFilterScroll.documentView)
                if quickFilterDocument.bounds.width > quickFilterScroll.contentView.bounds.width {
                    quickFilterScroll.contentView.scroll(to: NSPoint(
                        x: quickFilterDocument.bounds.width - quickFilterScroll.contentView.bounds.width,
                        y: 0
                    ))
                    quickFilterScroll.reflectScrolledClipView(quickFilterScroll.contentView)
                    quickFilters.view.layoutSubtreeIfNeeded()
                    #expect(quickFilterScroll.contentView.bounds.origin.x > 0)
                    quickFilterScroll.contentView.scroll(to: .zero)
                }
                for pane in content.panes {
                    #expect(pane.view.bounds.width > 0)
                    #expect(pane.view.bounds.height > 0)
                    #expect(pane.view.frame.maxX <= content.splitViewForTesting.bounds.width + 1)
                    let editor = try #require(filterEditor(in: pane))
                    let scroll = try #require(editor.view.enclosingScrollView)
                    #expect(scroll.isHidden == !showsFilter)
                    if showsFilter {
                        #expect(scroll.hasHorizontalScroller)
                        #expect(scroll.contentView.bounds.height >= editor.view.fittingSize.height - 1)
                        if editor.view.bounds.width > scroll.contentView.bounds.width {
                            scroll.contentView.scroll(to: NSPoint(x: editor.view.bounds.width - scroll.contentView.bounds.width, y: 0))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            pane.view.layoutSubtreeIfNeeded()
                            #expect(scroll.contentView.bounds.origin.x > 0)
                            scroll.contentView.scroll(to: .zero)
                        }
                    }
                }
            }
        }
    }

    // Opening a split defaults both inspectors to Bottom, but never locks the manual placement controls.
    @Test func splitOpeningDefaultsToBottomAndAllowsManualRightPlacement() throws {
        let defaults = UserDefaults(suiteName: "split-inspector-placement-\(UUID())")!
        defaults.set(NetworkInspectorPlacement.trailing.rawValue, forKey: "TCPViewer.inspectorPlacement")
        let owner = TCPViewerWindowController(
            services: .init(core: FakeTCPViewerCore(interfaceInventories: [[]])),
            configuration: AppConfiguration(defaults: defaults)
        )
        defer { owner.window?.close() }
        let first = owner.rootViewController
        #expect(first.viewModel.snapshot.inspectorPlacement == .trailing)
        owner.toggleSplitView(nil)
        let content = try #require(owner.selectedTab?.contentController)
        let second = try #require(content.secondPane)
        #expect(first.viewModel.snapshot.inspectorPlacement == .bottom)
        #expect(second.viewModel.snapshot.inspectorPlacement == .bottom)

        first.viewModel.toggleInspector(placement: .trailing)
        second.viewModel.toggleInspector(placement: .trailing)
        #expect(first.viewModel.snapshot.inspectorPlacement == .trailing)
        #expect(second.viewModel.snapshot.inspectorPlacement == .trailing)
        #expect(first.viewModel.snapshot.isInspectorVisible)
        #expect(second.viewModel.snapshot.isInspectorVisible)
        #expect(content.showSecondPane { preconditionFailure("An existing split must be reused") } === second)
        #expect(first.viewModel.snapshot.inspectorPlacement == .trailing)
        #expect(second.viewModel.snapshot.inspectorPlacement == .trailing)

        owner.toggleSplitView(nil)
        #expect(content.secondPane == nil)
        #expect(first.viewModel.snapshot.inspectorPlacement == .trailing)
        owner.toggleSplitView(nil)
        #expect(first.viewModel.snapshot.inspectorPlacement == .bottom)
        #expect(content.secondPane?.viewModel.snapshot.inspectorPlacement == .bottom)
        #expect(defaults.string(forKey: "TCPViewer.inspectorPlacement") == NetworkInspectorPlacement.trailing.rawValue)
    }

    @Test func splitPaneCopiesEveryLocalFilterThenChangesIndependently() throws {
        let core = FakeTCPViewerCore(interfaceInventories: [[]])
        let source = TCPViewerCaptureWorkspace(services: .init(core: core))
        let defaults = UserDefaults(suiteName: "split-state-\(UUID())")!
        let first = NetworkInspectorViewModel(
            services: source.controller.services,
            captureWorkspace: source,
            userDefaults: defaults
        )
        defer { first.close(); source.close() }
        let builder = PacketStructuredFilterGroup(filters: [
            PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp"),
        ])
        first.updateSourceListFilterText("source query")
        first.updateDisplayFilterText("protocol:tcp")
        first.toggleQuickFilter(.tcp)
        first.updateStructuredFilterGroup(builder)
        first.setStructuredFilterVisible(true)
        let customFilter = try first.saveCustomFilter(name: "TCP only", group: builder)
        first.selectWorkspaceMode(.overview)
        first.selectInspectorTab(.hex)
        first.rememberInspectorThickness(320, placement: .bottom)

        let copied = NetworkInspectorViewModel(
            services: source.controller.services,
            captureWorkspace: source,
            userDefaults: defaults,
            paneState: first.makeSplitPaneState()
        )
        #expect(copied.snapshot.sourceListFilterText == "source query")
        #expect(copied.snapshot.displayFilterText == "protocol:tcp")
        #expect(copied.snapshot.quickFilterSelection == PacketQuickFilterSelection(selectedIDs: [.tcp]))
        #expect(copied.snapshot.structuredFilterGroup == builder)
        #expect(copied.snapshot.workspaceMode == .overview)
        #expect(copied.snapshot.inspectorTab == .hex)
        #expect(copied.preferredInspectorThickness(for: 800, placement: .bottom) == 320)
        #expect(copied.snapshot.customFilterItems.first { $0.id == customFilter.id }?.isSelected == true)

        first.updateDisplayFilterText("protocol:udp")
        first.toggleQuickFilter(.udp)
        #expect(copied.snapshot.displayFilterText == "protocol:tcp")
        #expect(copied.snapshot.quickFilterSelection == PacketQuickFilterSelection(selectedIDs: [.tcp]))
        copied.close()

        first.setFilterMode(.wireshark)
        first.updateWiresharkFilterDraft("tcp.port == 443")
        let wiresharkCopy = NetworkInspectorViewModel(
            services: source.controller.services,
            captureWorkspace: source,
            userDefaults: defaults,
            paneState: first.makeSplitPaneState()
        )
        #expect(wiresharkCopy.snapshot.filterMode == .wireshark)
        #expect(wiresharkCopy.snapshot.wiresharkFilterState.draftExpression == "tcp.port == 443")
        #expect(wiresharkCopy.snapshot.structuredFilterGroup.filters.first?.text == "tcp.port == 443")
        #expect(wiresharkCopy.snapshot.structuredFilterGroup.filters.first?.query == .anyText)
        wiresharkCopy.close()
    }

    @Test func livePanesShareCaptureButKeepSelectionAndFiltersIndependent() async {
        let first = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let second = makePacket(packetNumber: 2, source: .live, transportHint: .udp)
        let live = FakeLiveSession()
        live.inspections = [first.id: makeInspection(for: first), second.id: makeInspection(for: second)]
        let core = FakeTCPViewerCore(interfaceInventories: [[makeInterface(id: "en0", displayName: "Test")]], liveSession: live)
        let source = TCPViewerCaptureWorkspace(services: .init(core: core))
        let defaults = UserDefaults(suiteName: "tabs-selection-\(UUID())")!
        let left = NetworkInspectorViewModel(services: source.controller.services, captureWorkspace: source, userDefaults: defaults)
        let right = NetworkInspectorViewModel(services: source.controller.services, captureWorkspace: source, userDefaults: defaults)
        await left.performInitialLoadIfNeeded()
        await right.performInitialLoadIfNeeded()
        await source.controller.startLiveCapture()
        live.send(.liveStateChanged(phase: .running, message: "Running"))
        live.send(.packetBatch([first, second], disposition: .append))
        await waitUntil { left.snapshot.totalPacketCount == 2 && right.snapshot.totalPacketCount == 2 }
        left.selectPacket(first.id)
        right.selectPacket(second.id)
        left.updateDisplayFilterText("protocol:tcp")
        right.updateDisplayFilterText("protocol:udp")
        await waitUntil { left.snapshot.base.inspectionState.inspection != nil && right.snapshot.base.inspectionState.inspection != nil }
        #expect(left.snapshot.selectedPacketID == first.id)
        #expect(right.snapshot.selectedPacketID == second.id)
        #expect(left.snapshot.packetRows.map(\.id) == [first.id])
        #expect(right.snapshot.packetRows.map(\.id) == [second.id])
        #expect(core.liveSessionRequests.count == 1)
        #expect(live.startCount == 1)
        left.deactivate()
        #expect(left.snapshot.packetRows.isEmpty)
        #expect(left.snapshot.base.packetIngestState.packets.isEmpty)
        #expect(!left.hasPendingCoalescedRebuildForTesting)
        // A capture burst updates the shared source while the hidden pane retains no packet render data.
        let burst = (3...10_002).map { makePacket(packetNumber: $0, source: .live, transportHint: .tcp) }
        live.send(.packetBatch(burst, disposition: .append))
        await waitUntil { source.controller.snapshot.packetIngestState.totalPacketCount == 10_002 }
        await waitUntil { right.snapshot.totalPacketCount == 10_002 }
        #expect(core.liveSessionRequests.count == 1)
        #expect(!left.hasPendingCoalescedRebuildForTesting)
        #expect(left.snapshot.packetRows.isEmpty)
        #expect(left.snapshot.base.packetIngestState.packets.isEmpty)
        left.activate()
        await waitUntil { left.snapshot.packetRows.count == 10_001 }
        #expect(left.snapshot.selectedPacketID == first.id)
        right.clearPackets()
        await waitUntil { left.snapshot.totalPacketCount == 0 }
        #expect(left.snapshot.selectedPacketID == nil)
        #expect(live.clearCapturedPacketsCount == 1)
        left.close()
        right.close()
        #expect(live.stopCount == 0)
        _ = await withCheckedContinuation { continuation in source.close { continuation.resume(returning: $0) } }
        #expect(live.stopCount == 1)
    }

    @Test func closingOfflineTabReleasesSourceAndDocumentAfterCallbacksDrain() async {
        weak var releasedDocument: FakeOfflineDocument?
        let core = FakeTCPViewerCore(interfaceInventories: [[]], documentFactory: { url in
            let document = FakeOfflineDocument(url: url, metadata: .init(format: .pcapng), openPlan: .completed([]))
            releasedDocument = document
            return document
        })
        var source: TCPViewerCaptureWorkspace? = TCPViewerCaptureWorkspace(services: .init(core: core), kind: .offline)
        weak var releasedSource = source
        let result = await source!.controller.importDocumentsWithResult(at: [URL(fileURLWithPath: "/tmp/tab-lifetime.pcapng")])
        #expect(result.error == nil)
        #expect(releasedDocument != nil)
        let tab = TCPViewerWorkspaceTab(source: source!)
        source = nil
        tab.close()
        await waitUntil { releasedSource == nil && releasedDocument == nil }
        #expect(releasedSource == nil)
        #expect(releasedDocument == nil)
    }

    @Test func cancelledMultiFileImportDoesNotAppendLatePacketsOrOpenRemainingFiles() async {
        let gate = AsyncGate()
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)
        let document = FakeOfflineDocument(url: URL(fileURLWithPath: "/tmp/tab-cancel.pcapng"), metadata: .init(format: .pcapng),
                                          openPlan: .init(batches: [[packet]], progress: [], error: nil, gate: gate))
        let core = FakeTCPViewerCore(interfaceInventories: [[]], documentFactory: { _ in document })
        let source = TCPViewerCaptureWorkspace(services: .init(core: core), kind: .offline)
        var completions = 0
        source.controller.importDocumentsWithResult(at: [document.url, URL(fileURLWithPath: "/tmp/tab-never-open.pcap")]) { result in
            completions += 1
            #expect((result.error as? TCPViewerCoreError)?.code == .operationCancelled)
        }
        await waitUntil { core.openedDocumentURLs.count == 1 }
        source.close()
        await gate.open()
        await waitUntil { completions == 1 }
        #expect(completions == 1)
        #expect(core.openedDocumentURLs.count == 1)
        #expect(source.controller.snapshot.packetIngestState.packets.isEmpty)
        #expect(document.cancelLoadingCount > 0)
    }

    @Test func workspaceTabOrderAndHistoryPreserveNeighborsWithoutRetainingTabs() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(TCPViewerWorkspaceTabOrder.selectionAfterClosing(ids[1], selectedID: ids[1], ids: ids) == ids[2])
        #expect(TCPViewerWorkspaceTabOrder.selectionAfterClosing(ids[2], selectedID: ids[2], ids: ids) == ids[1])
        #expect(TCPViewerWorkspaceTabOrder.tabsToClose(toRightOf: ids[0], ids: ids) == Array(ids.dropFirst()))
        #expect(TCPViewerWorkspaceTabOrder.destinationIndex(from: 0, insertionIndex: 3, count: 3) == 2)
        var history = TCPViewerWorkspaceTabHistory()
        ids.forEach { history.visit($0) }
        history.remove(ids[1])
        #expect(history.goBack(validIDs: Set([ids[0], ids[2]])) == ids[0])
        #expect(history.goForward(validIDs: Set([ids[0], ids[2]])) == ids[2])
    }

    @Test func windowTabsShareSidebarReusePanesCollapseTheWholeTabBarAndShowSidebarAtLaunch() async throws {
        let core = FakeTCPViewerCore(interfaceInventories: [[]])
        let defaults = UserDefaults(suiteName: "tabs-window-\(UUID())")!
        defaults.set(false, forKey: "TCPViewer.sidebarVisible")
        let owner = TCPViewerWindowController(services: .init(core: core), configuration: AppConfiguration(defaults: defaults))
        let first = try #require(owner.selectedTab)
        weak var firstPane = first.pane
        let sidebar = owner.workspaceViewController.sidebar
        #expect(owner.tabs.count == 1)
        #expect(owner.workspaceViewController.isSidebarVisibleForTesting)
        #expect(!owner.rootViewController.viewModel.prefersSidebarVisibleOnLaunch())
        #expect(owner.workspaceViewController.tabBarHeightForTesting == 0)
        #expect(owner.window?.tabbingMode == .disallowed)
        #expect(owner.rootViewController.children.flatMap(\.children).allSatisfy { !($0 is CaptureOverviewViewController) })
        owner.newWorkspaceTab(nil)
        let second = try #require(owner.selectedTab)
        weak var secondPane = second.pane
        #expect(owner.tabs.count == 2)
        #expect(owner.workspaceViewController.tabBarHeightForTesting == 34)
        #expect(first.source === second.source)
        #expect(first.contentController?.view.superview == nil)
        #expect(first.pane?.viewModel.isActive == false)
        owner.selectTab(first.id)
        #expect(owner.rootViewController === firstPane)
        #expect(owner.workspaceViewController.sidebar === sidebar)
        owner.closeTab(first.id)
        #expect(owner.selectedTabID == second.id)
        #expect(owner.workspaceViewController.tabBarHeightForTesting == 0)
        await waitUntil { firstPane == nil }
        #expect(firstPane == nil)
        owner.closeSelectedTab(nil)
        await waitUntil { owner.tabs.isEmpty }
        #expect(owner.tabs.isEmpty)
        #expect(owner.liveWorkspace.isClosed)
        await waitUntil { secondPane == nil }
        #expect(secondPane == nil)
        let reopened = TCPViewerWindowController(services: .init(core: core), configuration: AppConfiguration(defaults: defaults))
        #expect(reopened.tabs.count == 1)
        #expect(reopened.selectedTab?.isOffline == false)
        #expect(reopened.workspaceViewController.isSidebarVisibleForTesting)
        reopened.closeSelectedTab(nil)
        await waitUntil { reopened.tabs.isEmpty }
    }

    @Test func sourceListActionOpensClickedAppInNewSharedLiveTab() async throws {
        let client = PacketClient(
            pid: 123,
            name: "Sparkle",
            displayName: "Sparkle",
            executablePath: "/Applications/Sparkle.app/Contents/MacOS/Sparkle",
            bundleIdentifier: "org.sparkle-project.Sparkle",
            bundlePath: "/Applications/Sparkle.app"
        )
        let packet = makePacket(packetNumber: 1, source: .live, transportHint: .tcp, client: client)
        let appKey = try #require(PacketSourceListClassifier.clientIdentity(for: packet)?.key)
        let live = FakeLiveSession()
        let core = FakeTCPViewerCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Test")]],
            liveSession: live
        )
        let defaults = UserDefaults(suiteName: "tabs-source-list-new-tab-\(UUID())")!
        let owner = TCPViewerWindowController(
            services: .init(
                core: core,
                packetMetadataEnricher: PacketMetadataEnrichmentService(
                    clientResolver: WorkspaceFakePacketClientResolver(client: client)
                )
            ),
            configuration: AppConfiguration(defaults: defaults)
        )
        defer { owner.window?.close() }
        let original = owner.rootViewController
        await waitUntil {
            original.viewModel.snapshot.base.sessionState.selectedInterfaceID == "en0"
        }
        await owner.liveWorkspace.controller.startLiveCapture()
        live.send(.liveStateChanged(phase: .running, message: "Running"))
        live.send(.packetBatch([packet], disposition: .append))
        await waitUntil {
            owner.liveWorkspace.controller.snapshot.packetIngestState.packets.map(\.id) == [packet.id] &&
                original.viewModel.snapshot.sourceListSnapshot.contains(selection: .app(appKey))
        }

        original.sidebarViewController(
            owner.workspaceViewController.sidebar,
            didRequestOpenInNewTab: .app(appKey)
        )

        #expect(owner.tabs.count == 2)
        #expect(owner.selectedTab?.source === owner.liveWorkspace)
        #expect(owner.rootViewController !== original)
        #expect(owner.liveWorkspace.controller.snapshot.packetIngestState.packets.map(\.id) == [packet.id])
        #expect(owner.rootViewController.viewModel.snapshot.sourceListSnapshot.contains(selection: .app(appKey)))
        await waitUntil {
            owner.rootViewController.viewModel.snapshot.selectedSourceListSelection == .app(appKey) &&
                owner.rootViewController.viewModel.snapshot.packetRows.map(\.id) == [packet.id]
        }
        #expect(owner.rootViewController.viewModel.snapshot.selectedSourceListSelection == .app(appKey))
        #expect(owner.rootViewController.viewModel.snapshot.packetRows.map(\.id) == [packet.id])
        #expect(owner.workspaceViewController.tabBarHeightForTesting == 34)
    }

    @Test func sourceListActionCreatesAndReusesSplitPaneWithoutChangingFirstPane() async throws {
        let client = PacketClient(
            pid: 123,
            name: "Sparkle",
            displayName: "Sparkle",
            executablePath: "/Applications/Sparkle.app/Contents/MacOS/Sparkle",
            bundleIdentifier: "org.sparkle-project.Sparkle",
            bundlePath: "/Applications/Sparkle.app"
        )
        let packet = makePacket(packetNumber: 1, source: .live, transportHint: .tcp, client: client)
        let appKey = try #require(PacketSourceListClassifier.clientIdentity(for: packet)?.key)
        let ipKey = PacketSourceIPAddressKey(rawValue: "10.0.0.2")
        let live = FakeLiveSession()
        live.inspections[packet.id] = makeInspection(for: packet)
        let core = FakeTCPViewerCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Test")]],
            liveSession: live
        )
        let defaults = UserDefaults(suiteName: "split-source-list-\(UUID())")!
        let owner = TCPViewerWindowController(
            services: .init(
                core: core,
                packetMetadataEnricher: PacketMetadataEnrichmentService(
                    clientResolver: WorkspaceFakePacketClientResolver(client: client)
                )
            ),
            configuration: AppConfiguration(defaults: defaults)
        )
        defer { owner.window?.close() }
        let first = owner.rootViewController
        #expect(first.view.layer?.borderWidth == 0)
        await waitUntil { first.viewModel.snapshot.base.sessionState.selectedInterfaceID == "en0" }
        await owner.liveWorkspace.controller.startLiveCapture()
        live.send(.liveStateChanged(phase: .running, message: "Running"))
        live.send(.packetBatch([packet], disposition: .append))
        await waitUntil {
            first.viewModel.snapshot.sourceListSnapshot.contains(selection: .app(appKey)) &&
                first.viewModel.snapshot.sourceListSnapshot.contains(selection: .ipAddress(ipKey))
        }

        // A context click temporarily selects the target in the shared sidebar before the action runs.
        first.selectSourceListWhenAvailable(.app(appKey))
        await waitUntil { first.viewModel.snapshot.selectedSourceListSelection == .app(appKey) }
        first.viewModel.selectPacket(packet.id)
        await waitUntil {
            first.viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id
        }
        first.viewModel.selectDetailNode("frame.number")
        owner.tcpviewerRootViewController(
            first,
            didRequestOpenInSplitView: .app(appKey),
            preserving: .allPackets
        )

        let tab = try #require(owner.selectedTab)
        let second = try #require(tab.secondPane)
        let content = try #require(tab.contentController)
        #expect(tab.firstPane === first)
        #expect(tab.pane === second)
        #expect(!first.isFocusedPane)
        #expect(second.isFocusedPane)
        #expect(first.view.layer?.borderWidth == 0)
        #expect(second.view.layer?.borderWidth == 1)
        #expect(content.pane(containing: first.view) === first)
        #expect(content.pane(containing: second.view) === second)
        #expect(first.viewModel.captureWorkspace === second.viewModel.captureWorkspace)
        #expect(owner.tabs.count == 1)
        await waitUntil {
            first.viewModel.snapshot.selectedSourceListSelection == .allPackets &&
                second.viewModel.snapshot.selectedSourceListSelection == .app(appKey) &&
                second.viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id
        }
        #expect(second.viewModel.snapshot.selectedPacketID == packet.id)
        #expect(second.viewModel.snapshot.base.inspectionState.selectedDetailNodeID == "frame.number")
        #expect(first.viewModel.snapshot.inspectorPlacement == .bottom)
        #expect(second.viewModel.snapshot.inspectorPlacement == .bottom)
        #expect(first.viewModel.snapshot.isInspectorVisible)
        #expect(second.viewModel.snapshot.isInspectorVisible)
        #expect(core.liveSessionRequests.count == 1)
        #expect(live.startCount == 1)

        #expect(owner.window?.makeFirstResponder(first.view) == true)
        #expect(tab.pane === first)
        #expect(first.isFocusedPane)
        #expect(!second.isFocusedPane)
        #expect(first.view.layer?.borderWidth == 1)
        #expect(second.view.layer?.borderWidth == 0)
        #expect(owner.window?.makeFirstResponder(second.view) == true)
        #expect(tab.pane === second)

        let splitMenuItem = NSMenuItem(
            title: "Toggle Split View",
            action: #selector(TCPViewerWindowController.toggleSplitView(_:)),
            keyEquivalent: ""
        )
        #expect(owner.validateMenuItem(splitMenuItem))
        #expect(splitMenuItem.state == .on)

        second.viewModel.updateDisplayFilterText("right-only")
        owner.tcpviewerRootViewController(
            second,
            didRequestOpenInSplitView: .ipAddress(ipKey),
            preserving: .app(appKey)
        )
        #expect(tab.secondPane === second)
        await waitUntil { second.viewModel.snapshot.selectedSourceListSelection == .ipAddress(ipKey) }
        #expect(first.viewModel.snapshot.selectedSourceListSelection == .allPackets)
        #expect(second.viewModel.snapshot.displayFilterText == "right-only")

        owner.newWorkspaceTab(nil)
        #expect(!first.viewModel.isActive)
        #expect(!second.viewModel.isActive)
        owner.selectTab(tab.id)
        #expect(first.viewModel.isActive)
        #expect(second.viewModel.isActive)
        #expect(tab.isSplitViewVisible)

        owner.toggleSplitView(nil)
        #expect(tab.secondPane == nil)
        #expect(tab.pane === first)
        #expect(second.isClosed)
        #expect(second.viewModel.isClosed)
        #expect(first.view.layer?.borderWidth == 0)
        #expect(owner.liveWorkspace.subscriberCountForTesting == 1)
        #expect(owner.validateMenuItem(splitMenuItem))
        #expect(splitMenuItem.state == .off)
    }

    @Test func importerGroupsFilesInOfflineTabWithoutChangingSharedLiveSource() async throws {
        let core = FakeTCPViewerCore(interfaceInventories: [[]], documentFactory: { url in
            FakeOfflineDocument(url: url, metadata: .init(format: .pcapng), openPlan: .completed([]))
        })
        let defaults = UserDefaults(suiteName: "tabs-import-\(UUID())")!
        let owner = TCPViewerWindowController(services: .init(core: core), configuration: AppConfiguration(defaults: defaults))
        let liveTab = try #require(owner.selectedTab)
        let urls = [URL(fileURLWithPath: "/tmp/tab-group-a.pcap"), URL(fileURLWithPath: "/tmp/tab-group-b.pcapng")]
        let result = await withCheckedContinuation { continuation in
            owner.importCaptureURLs(urls, automaticNewTab: true) { continuation.resume(returning: $0) }
        }
        #expect(result.error == nil)
        #expect(result.importedURLs == urls)
        #expect(result.packetCount == 0)
        #expect(owner.tabs.count == 2)
        let offline = try #require(owner.selectedTab)
        #expect(offline.displayTitle == "2 Capture Files")
        #expect(offline.isOffline)
        #expect(offline.source !== liveTab.source)
        #expect(offline.pane?.viewModel.isOffline == true)
        let emptyWorkspace = PacketWorkspaceViewModel()
        emptyWorkspace.render(snapshot: offline.pane!.viewModel.snapshot)
        #expect(emptyWorkspace.emptyMessage == "This capture contains no packets.")
        #expect(offline.firstPane != nil)
        owner.toggleSplitView(nil)
        let offlineSecondPane = try #require(offline.secondPane)
        #expect(offlineSecondPane.viewModel.isOffline)
        #expect(offlineSecondPane.viewModel.captureWorkspace === offline.source)
        #expect(owner.tabs.count == 2)
        #expect(core.liveSessionRequests.isEmpty)
        owner.toggleSplitView(nil)
        #expect(offline.secondPane == nil)
        #expect(offlineSecondPane.isClosed)
        #expect(liveTab.source === owner.liveWorkspace)
        #expect(core.liveSessionRequests.isEmpty)
        let replacement = owner.makeOfflineWorkspace()
        weak var oldPane = offline.pane
        #expect(owner.placeImportedWorkspace(replacement, title: "Replacement", replacing: offline.id))
        #expect(owner.tabs.map(\.id) == [liveTab.id, offline.id])
        await waitUntil { oldPane == nil }
        #expect(oldPane == nil)
        #expect(offline.isClosed)
        #expect(!owner.placeImportedWorkspace(owner.makeOfflineWorkspace(), title: "Gone", replacing: UUID()))
        owner.window?.close()
    }

    @Test func closingPaneCompletesInspectionAndExportOnceAndIgnoresLateResults() async {
        let packet = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let live = FakeLiveSession()
        live.inspections[packet.id] = makeInspection(for: packet)
        let inspectionGate = AsyncGate()
        let exportGate = AsyncGate()
        live.inspectionGate = inspectionGate
        live.exportGate = exportGate
        let core = FakeTCPViewerCore(interfaceInventories: [[makeInterface(id: "en0", displayName: "Test")]], liveSession: live)
        let source = TCPViewerCaptureWorkspace(services: .init(core: core))
        var pane: NetworkInspectorViewModel? = NetworkInspectorViewModel(services: source.controller.services, captureWorkspace: source)
        weak var releasedPane = pane
        await source.controller.performInitialLoadIfNeeded()
        await source.controller.startLiveCapture()
        live.send(.packetBatch([packet], disposition: .append))
        await waitUntil { source.controller.snapshot.packetIngestState.totalPacketCount == 1 }
        var inspectionCompletions = 0
        var exportCompletions = 0
        pane?.inspectPacket(packet.id) { result in
            inspectionCompletions += 1
            if case .failure(let error) = result { #expect((error as? TCPViewerCoreError)?.code == .operationCancelled) }
            else { Issue.record("Closed inspection succeeded") }
        }
        pane?.exportPackets([packet.id], to: URL(fileURLWithPath: "/tmp/tab-cancel-export.pcapng"), format: .pcapng) { result in
            exportCompletions += 1
            if case .failure(let error) = result { #expect((error as? TCPViewerCoreError)?.code == .operationCancelled) }
            else { Issue.record("Closed export succeeded") }
        }
        await waitUntil { live.exportRequests.count == 1 }
        pane?.close()
        pane = nil
        #expect(inspectionCompletions == 1)
        #expect(exportCompletions == 1)
        #expect(releasedPane == nil)
        await inspectionGate.open()
        await exportGate.open()
        await waitUntil { source.subscriberCountForTesting == 0 }
        #expect(inspectionCompletions == 1)
        #expect(exportCompletions == 1)
        source.close()
    }

    @Test func sourceSerializesFilterGenerationsAndCancellationDoesNotClearAnotherPane() async {
        let packets = [makePacket(packetNumber: 1, source: .offline, transportHint: .tcp), makePacket(packetNumber: 2, source: .offline, transportHint: .udp)]
        let gate = AsyncGate()
        let document = FakeOfflineDocument(url: URL(fileURLWithPath: "/tmp/tab-filter.pcapng"), metadata: .init(format: .pcapng),
                                           openPlan: .completed(packets), displayFilterMatchesByExpression: ["tcp": [1], "udp": [2]])
        document.filterEvaluationGate = gate
        let core = FakeTCPViewerCore(interfaceInventories: [[]], documentFactory: { _ in document })
        let source = TCPViewerCaptureWorkspace(services: .init(core: core), kind: .offline)
        _ = await source.controller.importDocumentsWithResult(at: [document.url])
        let firstToken = DisplayFilterEvaluationCancellationToken()
        let secondToken = DisplayFilterEvaluationCancellationToken()
        var firstResult: Result<DisplayFilterMatchBatch, Error>?
        var secondResult: Result<DisplayFilterMatchBatch, Error>?
        source.controller.evaluateDisplayFilter("tcp", generation: 1, packetIDs: [1, 2], cancellationToken: firstToken) { firstResult = $0 }
        source.controller.evaluateDisplayFilter("udp", generation: 1, packetIDs: [1, 2], cancellationToken: secondToken) { secondResult = $0 }
        await waitUntil { document.displayFilterEvaluationRequests.count == 1 }
        #expect(document.displayFilterActivationGenerations.count == 1)
        firstToken.cancel()
        await gate.open()
        await waitUntil { firstResult != nil && secondResult != nil }
        if case .failure(let error) = firstResult { #expect((error as? TCPViewerCoreError)?.code == .operationCancelled) }
        else { Issue.record("The first pane's filter was not cancelled") }
        #expect((try? secondResult?.get().matchingPacketIDs) == [2])
        #expect((try? secondResult?.get().generation) == 1)
        #expect(Set(document.displayFilterActivationGenerations).count == 2)
        source.close()
    }

    @Test func workspaceAutomationKeepsCaptureLiveAndBindsPacketCommandsToOriginalPane() async throws {
        let live = FakeLiveSession()
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)
        let core = FakeTCPViewerCore(interfaceInventories: [[makeInterface(id: "en0", displayName: "Test")]], liveSession: live,
                                     documentFactory: { url in FakeOfflineDocument(url: url, metadata: .init(format: .pcapng), openPlan: .completed([packet])) })
        let defaults = UserDefaults(suiteName: "tabs-automation-\(UUID())")!
        let owner = TCPViewerWindowController(services: .init(core: core), configuration: AppConfiguration(defaults: defaults))
        let liveID = try #require(owner.selectedTabID)
        _ = await withCheckedContinuation { continuation in
            owner.importCaptureURLs([URL(fileURLWithPath: "/tmp/tab-command.pcapng")], automaticNewTab: true) { continuation.resume(returning: $0) }
        }
        let offlineID = try #require(owner.selectedTabID)
        let source = TCPViewerWorkspaceAutomationSource(windowController: owner)
        let command = source.sourceForCommand()
        owner.selectTab(liveID)
        #expect(command.mcpWorkspaceSnapshot().totalPacketCount == 1)
        #expect(source.mcpWorkspaceSnapshot().totalPacketCount == 0)
        let inspection = await withCheckedContinuation { continuation in command.mcpInspectPacket(id: 1) { continuation.resume(returning: $0) } }
        #expect((try? inspection.get().packetID) == 1)
        owner.selectTab(offlineID)
        var started: Result<Void, Error>?
        source.mcpStartCapture(interfaceID: "en0", captureFilter: nil) { started = $0 }
        await waitUntil { live.startCount == 1 }
        live.send(.liveStateChanged(phase: .running, message: "Running"))
        await waitUntil { started != nil }
        #expect((try? started?.get()) != nil)
        #expect(owner.selectedTabID == offlineID)
        #expect(core.liveSessionRequests.count == 1)
        owner.closeTab(offlineID)
        let unavailable = await withCheckedContinuation { continuation in command.mcpInspectPacket(id: 1) { continuation.resume(returning: $0) } }
        if case .success = unavailable { Issue.record("A closed command target was reused") }
        #expect(live.stopCount == 0)
        owner.window?.close()
    }

    @Test func importPlacementPolicyUsesTabCountAndSkipsAlertsForCLI() {
        #expect(!TCPViewerWorkspaceImporter.shouldAskForPlacement(tabCount: 0, automaticNewTab: false))
        #expect(!TCPViewerWorkspaceImporter.shouldAskForPlacement(tabCount: 1, automaticNewTab: false))
        #expect(TCPViewerWorkspaceImporter.shouldAskForPlacement(tabCount: 2, automaticNewTab: false))
        #expect(TCPViewerWorkspaceImporter.shouldAskForPlacement(tabCount: 8, automaticNewTab: false))
        #expect(!TCPViewerWorkspaceImporter.shouldAskForPlacement(tabCount: 8, automaticNewTab: true))
    }

    @Test func windowShortcutsAndTabContextMenusTargetTheIntendedTab() async throws {
        let defaults = UserDefaults(suiteName: "tabs-keys-\(UUID())")!
        let owner = TCPViewerWindowController(services: .init(core: FakeTCPViewerCore(interfaceInventories: [[]])),
                                               configuration: AppConfiguration(defaults: defaults))
        defer { owner.window?.close() }
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: owner.window?.windowNumber ?? 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
        }
        for _ in 0..<3 { #expect(owner.handleTabShortcut(key(kVK_ANSI_T, [.command]))) }
        let ids = owner.tabs.map(\.id)
        #expect(ids.count == 4)
        #expect(owner.handleTabShortcut(key(kVK_Tab, [.control])))
        #expect(owner.selectedTabID == ids[0])
        #expect(owner.handleTabShortcut(key(kVK_Tab, [.control, .shift])))
        #expect(owner.selectedTabID == ids[3])
        #expect(owner.handleTabShortcut(key(kVK_ANSI_2, [.command, .shift])))
        #expect(owner.selectedTabID == ids[1])
        #expect(owner.handleTabShortcut(key(kVK_ANSI_LeftBracket, [.command])))
        #expect(owner.selectedTabID == ids[3])
        #expect(owner.handleTabShortcut(key(kVK_ANSI_RightBracket, [.command])))
        #expect(owner.selectedTabID == ids[1])
        #expect(owner.handleTabShortcut(key(kVK_ANSI_RightBracket, [.command, .shift])))
        #expect(owner.selectedTabID == ids[2])
        #expect(owner.handleTabShortcut(key(kVK_ANSI_LeftBracket, [.command, .shift])))
        #expect(owner.selectedTabID == ids[1])
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let items = descendants(owner.workspaceViewController.tabBar).filter { String(describing: type(of: $0)) == "TCPViewerWorkspaceTabItem" }
        let clicked = try #require(items.first)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        let menu = try #require(clicked.menu(for: event))
        #expect(menu.items.map(\.title) == ["New Tab", "", "Close Tab", "Close Other Tabs", "Close Tabs to the Right"])
        let close = menu.items[2]
        #expect((close.representedObject as? UUID) == ids[0])
        NSApp.sendAction(close.action!, to: close.target, from: close)
        #expect(owner.tabs.map(\.id) == Array(ids.dropFirst()))
        #expect(owner.selectedTabID == ids[1])
        #expect(owner.handleTabShortcut(key(kVK_ANSI_W, [.command])))
        #expect(owner.selectedTabID == ids[2])
        owner.closeTabsToRight(of: ids[2])
        #expect(owner.tabs.map(\.id) == [ids[2]])
        #expect(owner.workspaceViewController.tabBarHeightForTesting == 0)
    }

    @Test func tabHistoryMenuItemsNavigateAndFollowHistoryAvailability() throws {
        let defaults = UserDefaults(suiteName: "tabs-history-menu-\(UUID())")!
        let owner = TCPViewerWindowController(
            services: .init(core: FakeTCPViewerCore(interfaceInventories: [[]])),
            configuration: AppConfiguration(defaults: defaults)
        )
        defer { owner.window?.close() }
        let firstID = try #require(owner.selectedTabID)
        let back = NSMenuItem(
            title: "Back",
            action: #selector(TCPViewerWindowController.navigateBackInTabHistory(_:)),
            keyEquivalent: "["
        )
        let forward = NSMenuItem(
            title: "Forward",
            action: #selector(TCPViewerWindowController.navigateForwardInTabHistory(_:)),
            keyEquivalent: "]"
        )

        #expect(!owner.validateMenuItem(back))
        #expect(!owner.validateMenuItem(forward))
        owner.newWorkspaceTab(nil)
        let secondID = try #require(owner.selectedTabID)
        #expect(owner.validateMenuItem(back))
        #expect(!owner.validateMenuItem(forward))

        owner.navigateBackInTabHistory(back)

        #expect(owner.selectedTabID == firstID)
        #expect(!owner.validateMenuItem(back))
        #expect(owner.validateMenuItem(forward))

        owner.navigateForwardInTabHistory(forward)

        #expect(owner.selectedTabID == secondID)
        #expect(owner.validateMenuItem(back))
        #expect(!owner.validateMenuItem(forward))
    }

    @Test func closingWindowCancelsQueuedImportsExactlyOnceWithoutCreatingPanes() async {
        let gate = AsyncGate()
        let document = FakeOfflineDocument(url: URL(fileURLWithPath: "/tmp/tab-queued.pcapng"), metadata: .init(format: .pcapng),
                                           openPlan: .init(batches: [], progress: [], error: nil, gate: gate))
        let core = FakeTCPViewerCore(interfaceInventories: [[]], documentFactory: { _ in document })
        let defaults = UserDefaults(suiteName: "tabs-queue-\(UUID())")!
        let owner = TCPViewerWindowController(services: .init(core: core), configuration: AppConfiguration(defaults: defaults), startsWithLiveTab: false)
        var completions = 0
        for _ in 0..<2 {
            owner.importCaptureURLs([document.url], automaticNewTab: true) { result in
                completions += 1
                #expect((result.error as? TCPViewerCoreError)?.code == .operationCancelled)
            }
        }
        await waitUntil { core.openedDocumentURLs.count == 1 }
        #expect(owner.tabs.isEmpty)
        owner.window?.close()
        #expect(completions == 2)
        await gate.open()
        #expect(owner.tabs.isEmpty)
        #expect(completions == 2)
        #expect(core.openedDocumentURLs.count == 1)
    }

    private func weakDescendants(of controller: NSViewController) -> [WeakTabTestObject] {
        controller.children.flatMap { [WeakTabTestObject($0)] + weakDescendants(of: $0) }
    }

    private func weakHierarchy(of controller: NSViewController) -> [WeakTabTestObject] {
        [WeakTabTestObject(controller)] + trackedView(controller.view) +
            weakViews(in: controller.view) + controller.children.flatMap { weakHierarchy(of: $0) }
    }

    private func weakViews(in view: NSView) -> [WeakTabTestObject] {
        view.subviews.flatMap { trackedView($0) + weakViews(in: $0) }
    }

    // NSSplitView keeps private implementation views cached after its controller is gone; track every app-owned view around them.
    private func trackedView(_ view: NSView) -> [WeakTabTestObject] {
        let typeName = String(describing: type(of: view))
        guard !(view is NSSplitView), !typeName.hasPrefix("_NSSplitView") else { return [] }
        return [WeakTabTestObject(view)]
    }

    @Test func controllerInitialLoadSelectsFirstEligibleInterface() async {
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
                makeInterface(id: "lo0", displayName: "Loopback", isLoopback: true),
                makeInterface(id: "bridge0", displayName: "Bridge", availability: .hidden, canCapture: false),
            ]]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.performInitialLoadIfNeeded()

        #expect(controller.snapshot.accessState == .ready)
        #expect(controller.snapshot.sessionState.phase == .ready)
        #expect(controller.snapshot.sessionState.interfaceInventory.map(\.id) == ["en0", "lo0", "bridge0"])
        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en0")
        #expect(controller.snapshot.sessionState.options.promiscuousMode)

        await tearDown(controller)
    }

    @Test func interfaceMenuSectionsGroupSimilarInterfaces() {
        let interfaces = [
            makeInterface(id: "pktap0", displayName: "All Interfaces"),
            makeInterface(id: "ap1", displayName: "Ethernet"),
            makeInterface(id: "en0", displayName: "Ethernet"),
            makeInterface(id: "en2", displayName: "Thunderbolt 1"),
            makeInterface(id: "en1", displayName: "Wi-Fi"),
            makeInterface(id: "lo0", displayName: "Loopback", isLoopback: true),
            makeInterface(id: "awdl0", displayName: "Apple Wireless Direct Link", availability: .unavailable, canCapture: false),
            makeInterface(id: "anpi0", displayName: "Ethernet", availability: .unavailable, canCapture: false),
            makeInterface(id: "gif0", displayName: "Generic Tunnel", availability: .unavailable, canCapture: false),
            makeInterface(id: "utun0", displayName: "VPN Tunnel", availability: .unavailable, canCapture: false),
        ]

        let sections = TCPViewerInterfaceMenuGrouper.sections(for: interfaces)

        #expect(sections.map(\.title) == ["All Interfaces", "Ethernet", "Thunderbolt", "Wi-Fi", "Loopback", "Tunnels"])
        #expect(sections.first { $0.title == "Ethernet" }?.interfaces.map(\.id) == ["ap1", "en0", "anpi0"])
        #expect(sections.first { $0.title == "Wi-Fi" }?.interfaces.map(\.id) == ["en1", "awdl0"])
        #expect(sections.first { $0.title == "Tunnels" }?.interfaces.map(\.id) == ["gif0", "utun0"])
    }

    @Test func interfacePopupMovesUncommonInterfacesIntoOtherSubmenu() throws {
        let interfaces = [
            makeInterface(id: "pktap0", displayName: "All Interfaces"),
            makeInterface(id: "ap1", displayName: "Ethernet"),
            makeInterface(id: "en0", displayName: "Ethernet"),
            makeInterface(id: "en2", displayName: "Thunderbolt 1"),
            makeInterface(id: "en1", displayName: "Wi-Fi"),
            makeInterface(id: "lo0", displayName: "Loopback", isLoopback: true),
            makeInterface(id: "awdl0", displayName: "Apple Wireless Direct Link", availability: .unavailable, canCapture: false),
            makeInterface(id: "anpi0", displayName: "Ethernet", availability: .unavailable, canCapture: false),
            makeInterface(id: "gif0", displayName: "Generic Tunnel", availability: .unavailable, canCapture: false),
            makeInterface(id: "utun0", displayName: "VPN Tunnel", availability: .unavailable, canCapture: false),
        ]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let actionTarget = InterfacePopupActionTarget()
        popup.target = actionTarget
        popup.action = #selector(InterfacePopupActionTarget.interfaceChanged(_:))

        TCPViewerInterfacePopupRenderer.configure(popup)
        TCPViewerInterfacePopupRenderer.render(
            popup,
            state: TCPViewerInterfacePopupState(
                interfaces: interfaces,
                selectedInterfaceID: "en1",
                lastUsedInterfaceIDs: [],
                activeInterfaceID: "en1",
                isCaptureLocked: false
            ),
            widthConstraint: nil
        )

        let menu = try #require(popup.menu)
        #expect(menu.items.compactMap { $0.representedObject as? String } == ["pktap0", "en0", "en1"])

        let otherItem = try #require(menu.items.first { $0.title == "Other" })
        let otherMenu = try #require(otherItem.submenu)
        let otherIDs = Set(otherMenu.items.compactMap { $0.representedObject as? String })
        #expect(otherIDs == Set(["ap1", "en2", "lo0", "awdl0", "anpi0", "gif0", "utun0"]))

        let otherInterfaceItems = otherMenu.items.filter { $0.representedObject is String }
        #expect(otherInterfaceItems.allSatisfy { ($0.target as AnyObject?) === actionTarget })
        #expect(otherInterfaceItems.allSatisfy { $0.action == #selector(InterfacePopupActionTarget.interfaceChanged(_:)) })
        #expect(otherMenu.items.first { $0.representedObject as? String == "awdl0" }?.isEnabled == false)
    }

    @Test func clearAllToolbarButtonTooltipShowsShortcut() throws {
        let dataSource = TCPViewerToolbarDataSource()

        let item = try #require(dataSource.toolbar(
            dataSource.toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("TCPViewer.ClearAll"),
            willBeInsertedIntoToolbar: true
        ))
        let button = try #require(item.view as? NSButton)
        #expect(button.toolTip == "Clear All Packets (⌘K)")
    }

    @Test func splitToolbarButtonRendersStateAndMigrationRunsOnlyOnce() throws {
        let suiteName = "split-toolbar-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dataSource = TCPViewerToolbarDataSource(userDefaults: defaults, autosavesConfiguration: false)
        let item = try #require(dataSource.toolbar(
            dataSource.toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("TCPViewer.SplitView"),
            willBeInsertedIntoToolbar: true
        ))
        let button = try #require(item.view as? NSButton)
        let inspector = NetworkInspectorViewModel(userDefaults: defaults)
        defer { inspector.close() }

        dataSource.render(
            snapshot: inspector.snapshot,
            inspectorViewModel: inspector,
            isLicenseAuthorized: true,
            isSplitViewVisible: false
        )
        #expect(button.state == .off)
        #expect(button.toolTip == "Show Split View")
        dataSource.render(
            snapshot: inspector.snapshot,
            inspectorViewModel: inspector,
            isLicenseAuthorized: true,
            isSplitViewVisible: true
        )
        #expect(button.state == .on)
        #expect(button.toolTip == "Hide Split View")

        dataSource.installSplitViewItemIfNeeded()
        #expect(defaults.bool(forKey: TCPViewerToolbarDataSource.splitViewMigrationKey))
        let defaultIdentifiers = dataSource.toolbarDefaultItemIdentifiers(dataSource.toolbar)
        let defaultSplitIndex = try #require(defaultIdentifiers.firstIndex(of: NSToolbarItem.Identifier("TCPViewer.SplitView")))
        let defaultInspectorIndex = try #require(defaultIdentifiers.firstIndex(of: NSToolbarItem.Identifier("TCPViewer.InspectorBottom")))
        #expect(defaultSplitIndex < defaultInspectorIndex)
        let splitIndex = try #require(dataSource.toolbar.items.firstIndex {
            $0.itemIdentifier == NSToolbarItem.Identifier("TCPViewer.SplitView")
        })
        dataSource.toolbar.removeItem(at: splitIndex)
        dataSource.installSplitViewItemIfNeeded()
        #expect(!dataSource.toolbar.items.contains {
            $0.itemIdentifier == NSToolbarItem.Identifier("TCPViewer.SplitView")
        })
    }

    @Test func interfacePopupWidthIncludesSelectedIcon() {
        let interfaces = [makeInterface(id: "en0", displayName: "Wi-Fi (en0)")]
        let plainPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let activePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let plainWidth = plainPopup.widthAnchor.constraint(equalToConstant: 0)
        let activeWidth = activePopup.widthAnchor.constraint(equalToConstant: 0)

        TCPViewerInterfacePopupRenderer.configure(plainPopup)
        TCPViewerInterfacePopupRenderer.render(
            plainPopup,
            state: TCPViewerInterfacePopupState(
                interfaces: interfaces,
                selectedInterfaceID: "en0",
                lastUsedInterfaceIDs: [],
                activeInterfaceID: nil,
                isCaptureLocked: false
            ),
            widthConstraint: plainWidth,
            maximumWidth: nil
        )
        TCPViewerInterfacePopupRenderer.configure(activePopup)
        TCPViewerInterfacePopupRenderer.render(
            activePopup,
            state: TCPViewerInterfacePopupState(
                interfaces: interfaces,
                selectedInterfaceID: "en0",
                lastUsedInterfaceIDs: [],
                activeInterfaceID: "en0",
                isCaptureLocked: false
            ),
            widthConstraint: activeWidth,
            maximumWidth: nil
        )

        #expect(activeWidth.constant > plainWidth.constant)
    }

    @Test func controllerInitialLoadSelectsActiveInterfaceBeforeFirstEligibleFallback() async {
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en7", displayName: "USB Ethernet"),
                makeInterface(id: "en0", displayName: "Wi-Fi"),
            ]]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore),
            activeInterfaceIDProvider: { "en0" }
        )

        await controller.performInitialLoadIfNeeded()

        #expect(controller.snapshot.accessState == .ready)
        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en0")
        #expect(controller.snapshot.sessionState.activeInterfaceID == "en0")

        await tearDown(controller)
    }

    @Test func initialLoadSelectsMostRecentStartedInterfaceBeforeActiveInterface() async {
        let suiteName = "TCPViewerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["en1"], forKey: InterfaceSelectionHistoryStore.storageKey)
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
                makeInterface(id: "en1", displayName: "USB Ethernet"),
            ]]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore),
            userDefaults: defaults,
            activeInterfaceIDProvider: { "en0" }
        )

        await controller.performInitialLoadIfNeeded()

        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en1")
        #expect(controller.snapshot.sessionState.lastUsedInterfaceIDs == ["en1"])
        #expect(controller.snapshot.sessionState.activeInterfaceID == "en0")

        await tearDown(controller)
    }

    @Test func initialLoadSelectsMostRecentStartedInterfaceWhenAvailable() async {
        let suiteName = "TCPViewerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["en1", "en0"], forKey: InterfaceSelectionHistoryStore.storageKey)
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
                makeInterface(id: "en1", displayName: "USB Ethernet"),
            ]]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore),
            userDefaults: defaults,
            activeInterfaceIDProvider: { nil }
        )

        await controller.performInitialLoadIfNeeded()

        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en1")
        #expect(controller.snapshot.sessionState.lastUsedInterfaceIDs == ["en1", "en0"])

        await tearDown(controller)
    }

    @Test func initialLoadKeepsRecentInterfaceEvenWhenUnavailable() async {
        let suiteName = "TCPViewerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["en9", "en0"], forKey: InterfaceSelectionHistoryStore.storageKey)
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
                makeInterface(id: "en9", displayName: "Old Interface", availability: .unavailable, canCapture: false),
            ]]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore),
            userDefaults: defaults
        )

        await controller.performInitialLoadIfNeeded()

        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en9")

        await tearDown(controller)
    }

    @Test func initialLoadFallsBackWhenRecentInterfaceMissingFromInventory() async {
        let suiteName = "TCPViewerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["en9"], forKey: InterfaceSelectionHistoryStore.storageKey)
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
            ]]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore),
            userDefaults: defaults
        )

        await controller.performInitialLoadIfNeeded()

        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en0")

        await tearDown(controller)
    }

    @Test func refreshClearsStaleInterfaceSelectionWhenInventoryChanges() async {
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [
                [makeInterface(id: "en0", displayName: "Wi-Fi")],
                [makeInterface(id: "utun0", displayName: "Tunnel", availability: .unavailable, reason: "Inactive service.")],
            ]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en0")

        await controller.refreshInterfaces()

        #expect(controller.snapshot.accessState == .blocked(.noEligibleInterfaces))
        #expect(controller.snapshot.sessionState.selectedInterfaceID == nil)
        #expect(controller.snapshot.sessionState.statusMessage.contains("no longer available"))

        await tearDown(controller)
    }

    @Test func liveCaptureLifecycleAppliesEventsAndHealth() async {
        let liveSession = FakeLiveSession()
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            liveSession: liveSession
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        await settleEventLoop()

        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .http1),
        ], disposition: .append))
        liveSession.send(.healthChanged(CaptureHealthSnapshot(
            packetsReceived: 2,
            packetsDropped: 1,
            packetsDroppedByInterface: 0,
            packetsObserved: 3,
            lastUpdated: Date(),
            statusMessage: "Healthy"
        )))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running &&
            controller.snapshot.sessionState.capturedPacketCount == 2 &&
            controller.snapshot.packetIngestState.totalPacketCount == 2 &&
            controller.snapshot.sessionState.health.packetsDropped == 1
        }

        #expect(liveSession.startCount == 1)
        #expect(controller.snapshot.sessionState.phase == .running)
        #expect(controller.snapshot.sessionState.capturedPacketCount == 2)
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 2)
        #expect(controller.snapshot.sessionState.health.packetsDropped == 1)

        await controller.pauseLiveCapture()
        liveSession.send(.liveStateChanged(phase: .paused, message: "Capture paused."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .paused
        }
        #expect(liveSession.pauseCount == 1)

        await controller.resumeLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture resumed."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }
        #expect(liveSession.resumeCount == 1)

        await controller.stopLiveCapture()
        liveSession.send(.liveStateChanged(phase: .stopped, message: "Capture stopped."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .stopped
        }
        #expect(liveSession.stopCount == 1)

        await tearDown(controller)
    }

    @Test func clearPacketsDuringRunningLiveCaptureClearsNativeSessionStore() async {
        let liveSession = FakeLiveSession()
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .udp),
        ], disposition: .append))
        await waitUntil {
            controller.snapshot.packetIngestState.totalPacketCount == 2
        }

        controller.clearPackets()

        #expect(liveSession.clearCapturedPacketsCount == 1)
        #expect(liveSession.stopCount == 0)
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 0)
        #expect(controller.snapshot.sessionState.capturedPacketCount == 0)

        await controller.stopLiveCapture()
        #expect(liveSession.stopCount == 1)

        await tearDown(controller)
    }

    @Test func terminationPreparationStopsRunningLiveCaptureOnce() async {
        let liveSession = FakeLiveSession()
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }

        let shouldTerminate = await controller.prepareForApplicationTermination()

        #expect(shouldTerminate)
        #expect(liveSession.stopCount == 1)

        await tearDown(controller)
    }

    @Test func terminationPreparationStopsFailedRetainedLiveCapture() async {
        let liveSession = FakeLiveSession()
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .failed, message: "Capture failed."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .failed
        }

        let shouldTerminate = await controller.prepareForApplicationTermination()

        #expect(shouldTerminate)
        #expect(liveSession.stopCount == 1)

        await tearDown(controller)
    }

    @Test func repeatedTerminationPreparationDoesNotStopReleasedLiveCaptureAgain() async {
        let liveSession = FakeLiveSession()
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }

        let firstPreparation = await controller.prepareForApplicationTermination()
        let secondPreparation = await controller.prepareForApplicationTermination()

        #expect(firstPreparation)
        #expect(secondPreparation)
        #expect(liveSession.stopCount == 1)

        await tearDown(controller)
    }

    @Test func terminationPreparationCancelsQuitWhenLiveStopFails() async {
        let liveSession = FakeLiveSession()
        liveSession.stopError = TCPViewerCoreError(code: .liveSessionControlFailed, message: "Stop failed.")
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }

        let shouldTerminate = await controller.prepareForApplicationTermination()

        #expect(!shouldTerminate)
        #expect(liveSession.stopCount == 1)
        #expect(controller.snapshot.sessionState.phase == .failed)
        #expect(controller.snapshot.sessionState.lastError?.code == .liveSessionControlFailed)

        await tearDown(controller)
    }

    @Test func refreshWhileCaptureIsRunningKeepsActiveSelection() async {
        let liveSession = FakeLiveSession()
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [
                [makeInterface(id: "en0", displayName: "Wi-Fi")],
                [makeInterface(id: "en0", displayName: "Wi-Fi", availability: .unavailable, reason: "Temporarily unavailable.", canCapture: false)],
            ],
            liveSession: liveSession
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }

        await controller.refreshInterfaces()

        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en0")
        #expect(controller.snapshot.sessionState.phase == .running)
        #expect(controller.snapshot.sessionState.statusMessage.contains("Keeping"))

        await tearDown(controller)
    }

    @Test func selectingAlternateInterfacePropagatesToLiveCapture() async {
        let liveSession = FakeLiveSession()
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
                makeInterface(id: "lo0", displayName: "Loopback", isLoopback: true),
            ]],
            liveSession: liveSession
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        controller.selectInterface("lo0")
        await controller.startLiveCapture()

        #expect(fakeCore.liveSessionRequests.last?.interfaceID == "lo0")
        #expect(liveSession.startCount == 1)

        await tearDown(controller)
    }

    @Test func liveCaptureStartsInNormalModeWhenInterfaceDoesNotSupportPromiscuousMode() async {
        let liveSession = FakeLiveSession()
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi", supportsPromiscuousMode: false),
            ]],
            liveSession: liveSession
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()

        #expect(controller.snapshot.sessionState.options.promiscuousMode == false)
        #expect(fakeCore.liveSessionRequests.last?.interfaceID == "en0")
        #expect(fakeCore.liveSessionRequests.last?.options.promiscuousMode == false)
        #expect(liveSession.startCount == 1)

        await tearDown(controller)
    }

    @Test func documentOpenReopenSaveAndSaveAsUpdateSnapshot() async {
        let openURL = URL(fileURLWithPath: "/tmp/session.pcapng")
        let saveAsURL = URL(fileURLWithPath: "/tmp/exported.pcap")
        let openPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp),
        ]
        let reopenPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .dns),
            makePacket(packetNumber: 3, source: .offline, transportHint: .dns),
        ]
        let document = FakeOfflineDocument(
            url: openURL,
            metadata: CaptureDocumentMetadata(
                format: .pcapng,
                operatingSystem: "macOS",
                hardware: "Apple",
                captureApplication: "TCPViewerTests",
                fileComment: "fixture"
            ),
            openPlan: .completed(openPackets),
            reopenPlan: .completed(reopenPackets),
            inspections: (openPackets + reopenPackets).reduce(into: [:]) { inspections, packet in
                inspections[packet.id] = makeInspection(for: packet)
            }
        )
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            documentFactory: { _ in document }
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.openDocument(at: openURL)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
            controller.snapshot.documentState.packetCount == 2
        }

        #expect(controller.snapshot.documentState.phase == .loaded)
        #expect(controller.snapshot.documentState.fileURL == openURL)
        #expect(controller.snapshot.documentState.packetCount == 2)
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 2)
        #expect(controller.snapshot.documentState.metadata?.captureApplication == "TCPViewerTests")
        #expect(controller.snapshot.loadState.progress.phase == .completed)

        await controller.reopenDocument()
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
            controller.snapshot.documentState.packetCount == 3
        }

        #expect(controller.snapshot.documentState.packetCount == 3)
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 3)

        await controller.saveDocument()
        await waitUntil {
            controller.snapshot.documentState.phase == .saved
        }
        #expect(document.saveCount == 1)

        await controller.saveDocument(to: saveAsURL, format: .pcap)
        await waitUntil {
            controller.snapshot.documentState.phase == .saved &&
            controller.snapshot.documentState.fileURL == saveAsURL
        }
        #expect(document.saveAsRequests.count == 1)
        #expect(controller.snapshot.documentState.fileURL == saveAsURL)
        #expect(controller.snapshot.documentState.format == .pcap)

        await tearDown(controller)
    }

    @Test func exportPacketsDoesNotMutateDocumentURL() async {
        let openURL = URL(fileURLWithPath: "/tmp/export-source.pcapng")
        let exportURL = URL(fileURLWithPath: "/tmp/export-copy.pcap")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .dns),
        ]
        let document = FakeOfflineDocument(
            url: openURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed(packets)
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { _ in document }
            ))
        )

        await controller.openDocument(at: openURL)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded
        }

        let result = await controller.exportPackets(withIDs: packets.map(\.id), to: exportURL, format: .pcap)

        guard case .success = result else {
            Issue.record("Expected export to succeed.")
            return
        }
        #expect(document.exportRequests.count == 1)
        #expect(document.exportRequests.first?.0 == packets.map(\.id))
        #expect(document.exportRequests.first?.1 == exportURL)
        #expect(document.exportRequests.first?.2 == .pcap)
        #expect(controller.snapshot.documentState.fileURL == openURL)
        #expect(controller.snapshot.documentState.format == .pcapng)

        await tearDown(controller)
    }

    @Test func importingMultipleCaptureFilesDedupesAndRoutesInspectionAndExportToOriginalDocuments() async {
        let firstURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/import-one.pcap"))
        let secondURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/import-two.pcapng"))
        let unsupportedURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/notes.txt"))
        let firstPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .tcp),
        ]
        let secondPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .dns),
            makePacket(packetNumber: 2, source: .offline, transportHint: .tls),
        ]
        let firstDocument = FakeOfflineDocument(
            url: firstURL,
            metadata: CaptureDocumentMetadata(format: .pcap),
            openPlan: .completed(firstPackets),
            inspections: Dictionary(uniqueKeysWithValues: firstPackets.map { ($0.id, makeInspection(for: $0)) })
        )
        let secondDocument = FakeOfflineDocument(
            url: secondURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed(secondPackets),
            inspections: Dictionary(uniqueKeysWithValues: secondPackets.map { ($0.id, makeInspection(for: $0)) })
        )
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            documentFactory: { url in
                url == secondURL ? secondDocument : firstDocument
            }
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.importDocuments(at: [firstURL, firstURL, unsupportedURL, secondURL])
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
                controller.snapshot.packetIngestState.totalPacketCount == 4
        }

        let importedFiles = controller.snapshot.packetIngestState.importedFiles
        let packets = controller.snapshot.packetIngestState.packets
        #expect(fakeCore.openedDocumentURLs == [firstURL, secondURL])
        #expect(importedFiles.map(\.displayName) == ["import-one.pcap", "import-two.pcapng"])
        #expect(importedFiles.map(\.packetCount) == [2, 2])
        #expect(packets.map(\.id) == [1, 2, 3, 4])
        #expect(packets.map(\.packetNumber) == [1, 2, 1, 2])
        #expect(controller.snapshot.documentState.fileURL == nil)

        await controller.importDocuments(at: [firstURL])
        #expect(fakeCore.openedDocumentURLs == [firstURL, secondURL])
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 4)

        controller.selectPacket(3)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == 3
        }
        #expect(controller.snapshot.inspectionState.inspection?.packetNumber == 1)
        #expect(controller.snapshot.inspectionState.inspection?.rawBytes == Data(repeating: 1, count: 64))

        let sameFileExport = await controller.exportPackets(withIDs: [3, 4], to: URL(fileURLWithPath: "/tmp/import-two-export.pcapng"), format: .pcapng)
        guard case .success = sameFileExport else {
            Issue.record("Expected same-file imported export to succeed.")
            return
        }
        #expect(secondDocument.exportRequests.first?.0 == [1, 2])
        #expect(firstDocument.exportRequests.isEmpty)

        let crossFileExport = await controller.exportPackets(withIDs: [1, 3], to: URL(fileURLWithPath: "/tmp/cross-file-export.pcapng"), format: .pcapng)
        guard case .failure(let error as TCPViewerCoreError) = crossFileExport else {
            Issue.record("Expected cross-file imported export to fail gracefully.")
            return
        }
        #expect(error.code == .offlineFileSaveFailed)
        #expect(error.message.contains("multiple imported files"))
        #expect(firstDocument.exportRequests.isEmpty)
        #expect(secondDocument.exportRequests.count == 1)

        await tearDown(controller)
    }

    @Test func importedDisplayFilterResultsRemapEachBackingDocumentToWorkspacePacketIDs() async throws {
        let firstURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/filter-import-one.pcap"))
        let secondURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/filter-import-two.pcapng"))
        let firstPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .tcp),
        ]
        let secondPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .dns),
            makePacket(packetNumber: 2, source: .offline, transportHint: .tls),
        ]
        let expression = "frame.number in {1, 2}"
        let firstDocument = FakeOfflineDocument(
            url: firstURL,
            metadata: CaptureDocumentMetadata(format: .pcap),
            openPlan: .completed(firstPackets),
            displayFilterMatchesByExpression: [expression: [2]]
        )
        let secondDocument = FakeOfflineDocument(
            url: secondURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed(secondPackets),
            displayFilterMatchesByExpression: [expression: [1]]
        )
        let controller = TCPViewerWorkspaceController(services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
            interfaceInventories: [[]],
            documentFactory: { $0 == secondURL ? secondDocument : firstDocument }
        )))

        await controller.importDocuments(at: [firstURL, secondURL])
        await waitUntil { controller.snapshot.packetIngestState.totalPacketCount == 4 }

        let result: Result<DisplayFilterMatchBatch, Error> = await withCheckedContinuation { continuation in
            controller.evaluateDisplayFilter(
                expression,
                generation: 9,
                packetIDs: [1, 2, 3, 4],
                cancellationToken: DisplayFilterEvaluationCancellationToken()
            ) { continuation.resume(returning: $0) }
        }
        let batch = try result.get()

        #expect(batch.evaluatedPacketIDs == [1, 2, 3, 4])
        #expect(batch.matchingPacketIDs == [2, 3])
        #expect(firstDocument.displayFilterEvaluationRequests == [[1, 2]])
        #expect(secondDocument.displayFilterEvaluationRequests == [[1, 2]])

        await tearDown(controller)
    }

    @Test func importingEmptyCaptureFileKeepsImportedFileStateAndDedupes() async {
        let captureURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/empty-import.pcapng"))
        let document = FakeOfflineDocument(
            url: captureURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed([])
        )
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            documentFactory: { _ in document }
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.importDocuments(at: [captureURL])
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
                controller.snapshot.packetIngestState.importedFiles.count == 1
        }

        let importedFile = controller.snapshot.packetIngestState.importedFiles.first
        #expect(fakeCore.openedDocumentURLs == [captureURL])
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 0)
        #expect(importedFile?.displayName == "empty-import.pcapng")
        #expect(importedFile?.packetCount == 0)

        await controller.importDocuments(at: [captureURL])
        #expect(fakeCore.openedDocumentURLs == [captureURL])

        await tearDown(controller)
    }

    @Test func captureImportResultReportsOnlyOpenedFilesAndTheFirstFailure() async throws {
        let openedURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/import-opened.pcap"))
        let failedURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/import-failed.pcapng"))
        let openedDocument = FakeOfflineDocument(
            url: openedURL,
            metadata: CaptureDocumentMetadata(format: .pcap),
            openPlan: .completed([makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)])
        )
        let importError = TCPViewerCoreError(code: .offlineFileOpenFailed, message: "Corrupt capture fixture.")
        let failedDocument = FakeOfflineDocument(
            url: failedURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: FakeOfflineDocument.LoadPlan(
                batches: [],
                progress: [],
                error: importError
            )
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { url in url == failedURL ? failedDocument : openedDocument }
            ))
        )

        let result = await controller.importDocumentsWithResult(at: [openedURL, failedURL])
        let reportedError = try #require(result.error as? TCPViewerCoreError)

        #expect(result.importedURLs == [openedURL])
        #expect(reportedError == importError)
        #expect(controller.snapshot.packetIngestState.importedFiles.map(\.url) == [openedURL])

        let duplicateResult = await controller.importDocumentsWithResult(at: [openedURL])
        #expect(duplicateResult.importedURLs.isEmpty)
        #expect(duplicateResult.error == nil)

        await tearDown(controller)
    }

    @Test func captureFileImportPolicyAcceptsOnlyPcapAndPcapNgExtensions() {
        #expect(TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL(URL(fileURLWithPath: "/tmp/sample.pcap")))
        #expect(TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL(URL(fileURLWithPath: "/tmp/sample.PCAPNG")))
        #expect(!TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL(URL(fileURLWithPath: "/tmp/sample.txt")))
        #expect(!TCPViewerCaptureFileImportPolicy.allowedContentTypes.isEmpty)
    }

    @Test func exportPacketsPausesAndResumesRunningLiveCapture() async {
        let exportURL = URL(fileURLWithPath: "/tmp/live-export.pcapng")
        let packets = [
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .udp),
        ]
        let liveSession = FakeLiveSession()
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch(packets, disposition: .append))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running &&
            controller.snapshot.packetIngestState.totalPacketCount == packets.count
        }

        let result = await controller.exportPackets(withIDs: packets.map(\.id), to: exportURL, format: .pcapng)

        guard case .success = result else {
            Issue.record("Expected live export to succeed.")
            return
        }
        #expect(liveSession.pauseCount == 1)
        #expect(liveSession.resumeCount == 1)
        #expect(liveSession.exportRequests.first?.0 == packets.map(\.id))
        #expect(liveSession.exportRequests.first?.1 == exportURL)

        await tearDown(controller)
    }

    @Test func exportPacketsResumesRunningLiveCaptureAfterCancellation() async {
        let exportURL = URL(fileURLWithPath: "/tmp/live-export-cancelled.pcapng")
        let packets = [makePacket(packetNumber: 1, source: .live, transportHint: .tcp)]
        let liveSession = FakeLiveSession()
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch(packets, disposition: .append))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running &&
            controller.snapshot.packetIngestState.totalPacketCount == packets.count
        }

        var cancellationChecks = 0
        let result = await withCheckedContinuation { continuation in
            controller.exportPackets(
                withIDs: packets.map(\.id),
                to: exportURL,
                format: .pcapng,
                shouldCancel: {
                    cancellationChecks += 1
                    return cancellationChecks > 1
                }
            ) { result in
                continuation.resume(returning: result)
            }
        }

        guard case .failure(let error as TCPViewerCoreError) = result else {
            Issue.record("Expected live export cancellation.")
            return
        }
        #expect(error.code == .operationCancelled)
        #expect(liveSession.pauseCount == 1)
        #expect(liveSession.resumeCount == 1)
        #expect(liveSession.exportRequests.isEmpty)

        await tearDown(controller)
    }

    @Test func exportTCPViewSessionPausesAndResumesRunningLiveCapture() async {
        let exportURL = URL(fileURLWithPath: "/tmp/live-session.tcpviewsession")
        let packets = [
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .udp),
        ]
        let liveSession = FakeLiveSession()
        let exportWriter = FakeTCPViewSessionExportWriter()
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch(packets, disposition: .append))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running &&
                controller.snapshot.packetIngestState.totalPacketCount == packets.count
        }

        let result = await withCheckedContinuation { continuation in
            controller.exportTCPViewSession(
                snapshot: makeSessionSnapshot(packets: packets, source: .live),
                to: exportURL,
                exportService: exportWriter
            ) { result in
                continuation.resume(returning: result)
            }
        }

        guard case .success = result else {
            Issue.record("Expected TCPViewer session export to succeed.")
            return
        }
        #expect(liveSession.pauseCount == 1)
        #expect(liveSession.resumeCount == 1)
        #expect(liveSession.exportRequests.first?.0 == packets.map(\.id))
        #expect(liveSession.exportRequests.first?.2 == .pcapng)
        #expect(exportWriter.requests.first?.snapshot.packets.map(\.id) == packets.map(\.id))
        #expect(exportWriter.requests.first?.destinationURL == exportURL)

        await tearDown(controller)
    }

    @Test func exportTCPViewSessionFlattensMultipleImportedFilesIntoOneCapture() async {
        let firstURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/session-import-one.pcapng"))
        let secondURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/session-import-two.pcapng"))
        let destinationURL = URL(fileURLWithPath: "/tmp/imported-session.tcpviewsession")
        let firstPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp),
        ]
        let secondPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .dns),
            makePacket(packetNumber: 2, source: .offline, transportHint: .tls),
        ]
        let firstDocument = FakeOfflineDocument(
            url: firstURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed(firstPackets)
        )
        let secondDocument = FakeOfflineDocument(
            url: secondURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed(secondPackets)
        )
        let exportWriter = FakeTCPViewSessionExportWriter()
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { url in
                    url == secondURL ? secondDocument : firstDocument
                }
            ))
        )

        await controller.importDocuments(at: [firstURL, secondURL])
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
                controller.snapshot.packetIngestState.totalPacketCount == 4
        }
        let sessionPackets = controller.snapshot.packetIngestState.packets

        let result = await withCheckedContinuation { continuation in
            controller.exportTCPViewSession(
                snapshot: makeSessionSnapshot(
                    packets: sessionPackets,
                    source: .offline,
                    importedFiles: controller.snapshot.packetIngestState.importedFiles,
                    importedPacketReferenceByID: controller.snapshot.packetIngestState.importedPacketReferenceByID
                ),
                to: destinationURL,
                exportService: exportWriter
            ) { result in
                continuation.resume(returning: result)
            }
        }

        guard case .success = result else {
            Issue.record("Expected imported TCPViewer session export to succeed.")
            return
        }
        #expect(firstDocument.exportRequests.map(\.0) == [[1, 2]])
        #expect(secondDocument.exportRequests.map(\.0) == [[1, 2]])
        #expect(exportWriter.requests.count == 1)
        #expect(exportWriter.requests.first?.snapshot.packets.map(\.id) == sessionPackets.map(\.id))

        await tearDown(controller)
    }

    @Test func openingSessionFileUsesImportStateWithoutChangingDocumentStatus() async throws {
        let existingURL = URL(fileURLWithPath: "/tmp/existing-session-source.pcapng")
        let existingPackets = [makePacket(packetNumber: 1, source: .offline, transportHint: .udp)]
        let sessionPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .tls),
        ]
        let package = try writeSessionPackage(named: "pending-status", packets: sessionPackets)
        defer { try? FileManager.default.removeItem(at: package.directoryURL) }

        let openGate = AsyncGate()
        let existingDocument = FakeOfflineDocument(
            url: existingURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed(existingPackets)
        )
        let sessionBackingDocument = FakeOfflineDocument(
            url: package.captureURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: FakeOfflineDocument.LoadPlan(
                batches: [sessionPackets],
                progress: [],
                error: nil,
                gate: openGate
            )
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { url in
                    url == existingURL ? existingDocument : sessionBackingDocument
                }
            ))
        )

        await controller.openDocument(at: existingURL)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded
        }
        let loadedDocumentState = controller.snapshot.documentState

        let openTask = Task {
            await controller.openDocument(at: package.sessionURL)
        }
        await waitUntil {
            controller.snapshot.sessionImportState.phase == .loading
        }

        #expect(controller.snapshot.documentState == loadedDocumentState)
        #expect(controller.snapshot.loadState.canCancel == false)
        #expect(controller.snapshot.sessionImportState.fileURL == package.sessionURL)
        #expect(controller.snapshot.sessionImportState.canCancel)

        await openGate.open()
        await openTask.value
        await waitUntil {
            controller.snapshot.documentState.fileURL == package.sessionURL &&
                controller.snapshot.documentState.phase == .loaded
        }

        #expect(controller.snapshot.sessionImportState.phase == .idle)
        #expect(controller.snapshot.packetIngestState.packets.map(\.id) == sessionPackets.map(\.id))

        await tearDown(controller)
    }

    @Test func cancellingSessionImportKeepsCurrentDocumentAndIgnoresLateCompletion() async throws {
        let existingURL = URL(fileURLWithPath: "/tmp/existing-before-cancel.pcapng")
        let existingPackets = [makePacket(packetNumber: 1, source: .offline, transportHint: .dns)]
        let sessionPackets = [makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)]
        let package = try writeSessionPackage(named: "cancelled-session", packets: sessionPackets)
        defer { try? FileManager.default.removeItem(at: package.directoryURL) }

        let openGate = AsyncGate()
        let existingDocument = FakeOfflineDocument(
            url: existingURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed(existingPackets)
        )
        let sessionBackingDocument = FakeOfflineDocument(
            url: package.captureURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: FakeOfflineDocument.LoadPlan(
                batches: [sessionPackets],
                progress: [],
                error: nil,
                gate: openGate
            )
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { url in
                    url == existingURL ? existingDocument : sessionBackingDocument
                }
            ))
        )

        await controller.openDocument(at: existingURL)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded
        }
        let loadedDocumentState = controller.snapshot.documentState

        let openTask = Task {
            await controller.openDocument(at: package.sessionURL)
        }
        await waitUntil {
            controller.snapshot.sessionImportState.phase == .loading
        }

        await controller.cancelSessionImport()
        #expect(sessionBackingDocument.cancelLoadingCount == 1)
        #expect(controller.snapshot.sessionImportState.phase == .idle)
        #expect(controller.snapshot.documentState == loadedDocumentState)

        await openGate.open()
        await openTask.value
        await settleEventLoop()

        #expect(controller.snapshot.documentState == loadedDocumentState)
        #expect(controller.snapshot.packetIngestState.packets.map(\.id) == existingPackets.map(\.id))

        await tearDown(controller)
    }

    @Test func openingNewDocumentIgnoresEventsFromPreviousDocumentStream() async {
        let firstURL = URL(fileURLWithPath: "/tmp/first-stream.pcapng")
        let secondURL = URL(fileURLWithPath: "/tmp/second-stream.pcapng")
        let stalePacket = makePacket(packetNumber: 1, source: .offline, transportHint: .udp)
        let secondPacket = makePacket(packetNumber: 1, source: .offline, transportHint: .dns)
        let secondOpenGate = AsyncGate()

        let firstDocument = FakeOfflineDocument(
            url: firstURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed([stalePacket])
        )
        let secondDocument = FakeOfflineDocument(
            url: secondURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: FakeOfflineDocument.LoadPlan(
                batches: [[secondPacket]],
                progress: [],
                error: nil,
                gate: secondOpenGate
            ),
            inspections: [secondPacket.id: makeInspection(for: secondPacket)]
        )
        let staleProgress = PacketLoadProgress(
            phase: .cancelled,
            loadedPacketCount: 99,
            isPartialResult: true,
            message: "Stale load was cancelled."
        )
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            documentFactory: { url in
                if url == secondURL {
                    firstDocument.send(.packetBatch([stalePacket], disposition: .append))
                    firstDocument.send(.loadProgressChanged(staleProgress))
                    return secondDocument
                }

                return firstDocument
            }
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore)
        )

        await controller.openDocument(at: firstURL)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded
        }

        let openTask = Task {
            await controller.openDocument(at: secondURL)
        }
        await waitUntil {
            controller.snapshot.documentState.fileURL == secondURL &&
            controller.snapshot.documentState.phase == .opening
        }
        await settleEventLoop()

        #expect(controller.snapshot.packetIngestState.totalPacketCount == 0)
        #expect(controller.snapshot.documentState.isPartialResult == false)

        await secondOpenGate.open()
        await openTask.value

        #expect(controller.snapshot.documentState.phase == .loaded)
        #expect(controller.snapshot.packetIngestState.packets.map(\.transportHint) == [.dns])

        await tearDown(controller)
    }

    @Test func selectingPacketLoadsInspectionAndHighlightsDetailByteRange() async {
        let url = URL(fileURLWithPath: "/tmp/inspection.pcapng")
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)
        let inspection = makeInspection(
            for: packet,
            detailNodes: [
                PacketDetailNode(
                    id: "frame",
                    name: "Frame",
                    value: "Packet 1",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "frame.number", name: "Frame Number", value: "1")
                    ]
                ),
                PacketDetailNode(
                    id: "ipv4",
                    name: "IPv4",
                    value: "10.0.0.1 -> 10.0.0.2",
                    kind: .layer,
                    byteRange: PacketByteRange(offset: 14, length: 20),
                    children: [
                        PacketDetailNode(
                            id: "ipv4.src",
                            name: "Source",
                            value: "10.0.0.1",
                            byteRange: PacketByteRange(offset: 26, length: 4)
                        ),
                        PacketDetailNode(
                            id: "ipv4.dst",
                            name: "Destination",
                            value: "10.0.0.2",
                            byteRange: PacketByteRange(offset: 30, length: 4)
                        ),
                        PacketDetailNode(
                            id: "ipv4.flags.df",
                            name: "Don't Fragment",
                            value: "Set",
                            byteRange: PacketByteRange(offset: 20, length: 1, bitOffset: 1, bitLength: 1, hasBitRange: true)
                        ),
                    ]
                ),
            ]
        )
        let document = FakeOfflineDocument(
            url: url,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed([packet]),
            inspections: [packet.id: inspection]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { _ in document }
            ))
        )

        await controller.openDocument(at: url)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded
        }

        controller.selectPacket(packet.id)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == packet.id &&
            !controller.snapshot.inspectionState.isLoading
        }

        #expect(controller.snapshot.selectedPacketID == packet.id)
        #expect(controller.snapshot.inspectionState.inspection?.rawBytes.count == 64)
        #expect(controller.snapshot.inspectionState.statusMessage.contains("1"))

        controller.selectDetailNode("ipv4.src")

        #expect(controller.snapshot.inspectionState.selectedDetailNodeID == "ipv4.src")
        #expect(controller.snapshot.inspectionState.highlightedByteRange == PacketByteRange(offset: 26, length: 4))

        controller.selectDetailNode("ipv4.flags.df")

        #expect(controller.snapshot.inspectionState.selectedDetailNodeID == "ipv4.flags.df")
        #expect(controller.snapshot.inspectionState.highlightedByteRange == PacketByteRange(offset: 20, length: 1, bitOffset: 1, bitLength: 1, hasBitRange: true))

        await tearDown(controller)
    }

    @Test func navigationMovesAcrossVisiblePacketsAndValidatesJumpInput() async {
        let url = URL(fileURLWithPath: "/tmp/navigation.pcapng")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 3, source: .offline, transportHint: .dns),
        ]
        let document = FakeOfflineDocument(
            url: url,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed(packets),
            inspections: Dictionary(uniqueKeysWithValues: packets.map { ($0.id, makeInspection(for: $0)) })
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { _ in document }
            ))
        )

        await controller.openDocument(at: url)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded
        }

        controller.selectPacket(packets[0].id)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == packets[0].id
        }

        controller.selectNextPacket()
        await waitUntil {
            controller.snapshot.selectedPacketID == packets[1].id &&
            controller.snapshot.inspectionState.inspection?.packetID == packets[1].id
        }
        #expect(controller.snapshot.inspectionState.inspection?.packetID == packets[1].id)

        controller.selectPreviousPacket()
        await waitUntil {
            controller.snapshot.selectedPacketID == packets[0].id
        }

        controller.updateJumpText("abc")
        controller.jumpToPacketNumber()
        #expect(controller.snapshot.navigationState.jumpErrorMessage == "Enter a valid packet number.")

        controller.updateJumpText("99")
        controller.jumpToPacketNumber()
        #expect(controller.snapshot.navigationState.jumpErrorMessage == "Packet 99 is not visible right now.")

        controller.updateJumpText("3")
        controller.jumpToPacketNumber()
        await waitUntil {
            controller.snapshot.selectedPacketID == packets[2].id &&
            controller.snapshot.inspectionState.inspection?.packetID == packets[2].id
        }
        #expect(controller.snapshot.navigationState.jumpErrorMessage == nil)
        #expect(controller.snapshot.inspectionState.inspection?.packetID == packets[2].id)

        await tearDown(controller)
    }

    @Test func livePacketAppendsKeepExistingSelectionAnchored() async {
        let liveSession = FakeLiveSession()
        let firstPacket = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let secondPacket = makePacket(packetNumber: 2, source: .live, transportHint: .udp)
        liveSession.inspections[firstPacket.id] = makeInspection(for: firstPacket)
        liveSession.inspections[secondPacket.id] = makeInspection(for: secondPacket)

        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([firstPacket], disposition: .append))
        await waitUntil {
            controller.snapshot.packetIngestState.totalPacketCount == 1
        }

        controller.selectPacket(firstPacket.id)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == firstPacket.id
        }

        liveSession.send(.packetBatch([secondPacket], disposition: .append))
        await waitUntil {
            controller.snapshot.packetIngestState.totalPacketCount == 2
        }

        #expect(controller.snapshot.selectedPacketID == firstPacket.id)
        #expect(controller.snapshot.inspectionState.inspection?.packetID == firstPacket.id)
        #expect(controller.snapshot.navigationState.visiblePacketIDs == [firstPacket.id, secondPacket.id])

        await tearDown(controller)
    }

    @Test func captureFilterPreferencesLoadPersistAndPropagateToLiveCapture() async {
        let suiteName = "TCPViewerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(" udp port 53 ", forKey: "TCPViewer.captureFilterText")
        defaults.set(["port 80", "tcp"], forKey: "TCPViewer.recentCaptureFilters")

        let liveSession = FakeLiveSession()
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            liveSession: liveSession,
            captureFilterValidator: { expression in
                let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
                return CaptureFilterValidation(disposition: .valid, normalizedExpression: trimmed, message: nil)
            }
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore),
            userDefaults: defaults
        )

        #expect(controller.snapshot.filterState.captureFilterText == " udp port 53 ")
        #expect(controller.snapshot.filterState.recentCaptureFilters == ["port 80", "tcp"])

        await controller.refreshInterfaces()
        await controller.startLiveCapture()

        #expect(liveSession.startCount == 1)
        #expect(fakeCore.liveSessionRequests.count == 1)
        #expect(fakeCore.liveSessionRequests.last?.interfaceID == "en0")
        #expect(fakeCore.liveSessionRequests.last?.options.captureFilterExpression == "udp port 53")
        #expect(controller.snapshot.filterState.captureFilterText == "udp port 53")
        #expect(defaults.string(forKey: "TCPViewer.captureFilterText") == "udp port 53")
        #expect(defaults.stringArray(forKey: "TCPViewer.recentCaptureFilters")?.first == "udp port 53")

        await tearDown(controller)
    }

    @Test func liveCapturePersistsStartedInterfaceAsMostRecentLastUsed() async {
        let suiteName = "TCPViewerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["en0"], forKey: InterfaceSelectionHistoryStore.storageKey)

        let liveSession = FakeLiveSession()
        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
                makeInterface(id: "en1", displayName: "USB Ethernet"),
            ]],
            liveSession: liveSession
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore),
            userDefaults: defaults
        )

        #expect(controller.snapshot.sessionState.lastUsedInterfaceIDs == ["en0"])

        await controller.refreshInterfaces()
        controller.selectInterface("en1")
        await controller.startLiveCapture()

        #expect(liveSession.startCount == 1)
        #expect(controller.snapshot.sessionState.lastUsedInterfaceIDs == ["en1", "en0"])
        #expect(defaults.stringArray(forKey: InterfaceSelectionHistoryStore.storageKey) == ["en1", "en0"])

        await tearDown(controller)
    }

    @Test func selectingInterfaceWithoutStartingCaptureDoesNotPersistLastUsed() async {
        let suiteName = "TCPViewerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fakeCore = FakeTCPViewerCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
                makeInterface(id: "en1", displayName: "USB Ethernet"),
            ]]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: fakeCore),
            userDefaults: defaults
        )

        await controller.refreshInterfaces()
        controller.selectInterface("en1")

        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en1")
        #expect(controller.snapshot.sessionState.lastUsedInterfaceIDs.isEmpty)
        #expect(defaults.stringArray(forKey: InterfaceSelectionHistoryStore.storageKey) == nil)

        await tearDown(controller)
    }

    @Test func partialDocumentLoadKeepsLoadedPacketsAndDisablesSave() async {
        let url = URL(fileURLWithPath: "/tmp/partial-load.pcapng")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp),
        ]
        let cancelledProgress = PacketLoadProgress(
            phase: .cancelled,
            loadedPacketCount: packets.count,
            processedBytes: 128,
            totalBytes: 256,
            isPartialResult: true,
            message: "Loading cancelled after 2 packets from partial-load.pcapng."
        )
        let document = FakeOfflineDocument(
            url: url,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: FakeOfflineDocument.LoadPlan(
                batches: [[packets[0]], [packets[1]]],
                progress: [
                    PacketLoadProgress(
                        phase: .loading,
                        loadedPacketCount: 1,
                        processedBytes: 64,
                        totalBytes: 256,
                        isPartialResult: false,
                        message: "Loaded 1 packets from partial-load.pcapng…"
                    ),
                    cancelledProgress,
                ],
                error: TCPViewerCoreError(
                    code: .operationCancelled,
                    message: "Loading partial-load.pcapng was cancelled after 2 packets."
                )
            ),
            inspections: Dictionary(uniqueKeysWithValues: packets.map { ($0.id, makeInspection(for: $0)) })
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { _ in document }
            ))
        )

        await controller.openDocument(at: url)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
            controller.snapshot.documentState.isPartialResult
        }

        #expect(controller.snapshot.packetIngestState.totalPacketCount == 2)
        #expect(controller.snapshot.documentState.packetCount == 2)
        #expect(controller.snapshot.documentState.isPartialResult)
        #expect(controller.snapshot.documentState.canSave == false)
        #expect(controller.snapshot.documentState.canSaveAs == false)
        #expect(controller.snapshot.loadState.progress.phase == .cancelled)
        #expect(controller.snapshot.loadState.progress.isPartialResult)

        controller.selectPacket(packets[0].id)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == packets[0].id
        }
        #expect(controller.snapshot.inspectionState.inspection?.packetID == packets[0].id)

        await tearDown(controller)
    }

    @Test func clearPacketsResetsSelectionInspectionAndNavigation() async {
        let url = URL(fileURLWithPath: "/tmp/clear-packets.pcapng")
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)
        let document = FakeOfflineDocument(
            url: url,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed([packet]),
            inspections: [packet.id: makeInspection(for: packet)]
        )
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: FakeTCPViewerCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { _ in document }
            ))
        )

        await controller.openDocument(at: url)
        await waitUntil {
            controller.snapshot.packetIngestState.totalPacketCount == 1
        }
        controller.selectPacket(packet.id)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == packet.id
        }

        controller.clearPackets()

        #expect(controller.snapshot.packetIngestState.totalPacketCount == 0)
        #expect(controller.snapshot.documentState.packetCount == 0)
        #expect(controller.snapshot.navigationState.visiblePacketIDs.isEmpty)
        #expect(controller.snapshot.selectedPacketID == nil)
        #expect(controller.snapshot.inspectionState.inspection == nil)
        #expect(controller.snapshot.inspectionState.highlightedByteRange == nil)

        await tearDown(controller)
    }

    private func makeInterface(
        id: String,
        displayName: String,
        isLoopback: Bool = false,
        availability: CaptureInterfaceAvailability = .available,
        reason: String? = nil,
        canCapture: Bool = true,
        supportsPromiscuousMode: Bool? = nil
    ) -> CaptureInterfaceSummary {
        CaptureInterfaceSummary(
            id: id,
            technicalName: id,
            displayName: displayName,
            friendlyName: nil,
            interfaceDescription: nil,
            isLoopback: isLoopback,
            addresses: [],
            linkType: isLoopback ? .loopback : .ethernet,
            availability: availability,
            availabilityReason: reason,
            activityPreview: CaptureInterfaceActivityPreview(),
            capabilities: CaptureInterfaceCapabilities(
                canCapture: canCapture,
                supportsPromiscuousMode: supportsPromiscuousMode ?? !isLoopback,
                requiresBPFPermissionSetup: true,
                providesMacOSMetadata: true
            )
        )
    }

    private func makePacket(
        packetNumber: UInt64,
        source: CaptureSource,
        transportHint: TransportProtocolHint,
        layers: [PacketLayer]? = nil,
        followStreamID: FollowStreamID? = nil,
        client: PacketClient? = nil
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: source,
            interfaceID: source == .live ? "en0" : nil,
            transportHint: transportHint,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 80)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: 42,
            followStreamID: followStreamID,
            infoSummary: "Packet \(packetNumber)",
            layers: layers ?? [PacketLayer(name: "Ethernet"), PacketLayer(name: source == .live ? "IPv4" : "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            client: client
        )
    }

    private func makeInspection(
        for packet: PacketSummary,
        detailNodes: [PacketDetailNode]? = nil
    ) -> PacketInspection {
        PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data(repeating: UInt8(packet.packetNumber), count: 64),
            detailNodes: detailNodes ?? [
                PacketDetailNode(
                    id: "frame",
                    name: "Frame",
                    value: "Packet \(packet.packetNumber)",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "frame.number", name: "Frame Number", value: "\(packet.packetNumber)")
                    ]
                )
            ],
            decodeStatus: packet.decodeStatus
        )
    }

    private func makeSessionSnapshot(
        packets: [PacketSummary],
        source: CaptureSource,
        importedFiles: [ImportedCaptureFile] = [],
        importedPacketReferenceByID: [PacketSummary.ID: ImportedPacketReference] = [:]
    ) -> TCPViewSessionExportSnapshot {
        TCPViewSessionExportSnapshot(
            packets: packets,
            source: source,
            backingIdentity: "test-backing",
            importedFiles: importedFiles,
            importedPacketReferenceByID: importedPacketReferenceByID,
            pins: [],
            savedPackets: [],
            customFilters: [],
            quickFilterSelection: .all,
            structuredFilterGroup: .default,
            displayFilterText: "",
            sourceListFilterText: "",
            selectedPacketID: packets.first?.id,
            selectedSourceListSelection: .allPackets,
            workspaceMode: .packets,
            inspectorTab: .detail,
            inspectorPlacement: .trailing,
            isInspectorVisible: true,
            isStructuredFilterVisible: false,
            tableColumnLayout: nil,
            sourceMetadata: TCPViewSessionSourceMetadata(
                fileName: "test.pcapng",
                filePath: "/tmp/test.pcapng",
                format: "pcapng",
                packetCount: packets.count
            )
        )
    }

    private func writeSessionPackage(
        named name: String,
        packets: [PacketSummary]
    ) throws -> (sessionURL: URL, captureURL: URL, directoryURL: URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewerWorkspaceControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let captureURL = directoryURL.appendingPathComponent("\(name).pcapng")
        let sessionURL = directoryURL.appendingPathComponent("\(name).tcpviewsession")
        try Data("pcapng-placeholder".utf8).write(to: captureURL)
        try TCPViewSessionExportService().writePackage(
            snapshot: makeSessionSnapshot(packets: packets, source: .offline),
            captureFileURL: captureURL,
            to: sessionURL,
            progress: nil,
            shouldCancel: nil
        )
        return (sessionURL, captureURL, directoryURL)
    }

    private func settleEventLoop() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))

        while ContinuousClock.now < deadline {
            if condition() {
                return
            }

            await settleEventLoop()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func tearDown(_ controller: TCPViewerWorkspaceController) async {
        controller.cancelBackgroundWork()
        await settleEventLoop()
        await settleEventLoop()
    }
}

private final class InterfacePopupActionTarget: NSObject {
    @objc func interfaceChanged(_ sender: Any) {}
}

@Suite
struct PacketIngestStateMutationTests {

    @Test func followCaptureIdentityRejectsReusedPacketIDsAfterLineageChanges() {
        var state = PacketIngestState.empty
        let packet = makePacket(packetNumber: 1)
        state.append([packet], source: .live)
        let identity = FollowStreamCaptureIdentity(ingestState: state)

        #expect(identity.canReveal(packetID: packet.id, in: state))
        #expect(!identity.canReveal(packetID: 99, in: state))

        state.reset(source: .live, message: "New capture")
        state.append([packet], source: .live)

        #expect(!identity.canReveal(packetID: packet.id, in: state))
    }

    @Test func appendAndApplyMetadataUpdatesEmitsAppendWhenNoUpdates() {
        var state = PacketIngestState.empty
        let packet = makePacket(packetNumber: 1)

        state.appendAndApplyMetadataUpdates([packet], metadataUpdates: [], source: .live)

        #expect(state.lastMutation == .append(0..<1))
        #expect(state.packets.count == 1)
    }

    @Test func appendAndApplyMetadataUpdatesFoldsBackfillForNewlyAppendedPackets() {
        var state = PacketIngestState.empty
        let packet = makePacket(packetNumber: 1)
        let updates = [
            PacketMetadataUpdate(
                packetIDs: [packet.id],
                sniDomainName: "api.example.com",
                client: nil,
                direction: nil
            )
        ]

        state.appendAndApplyMetadataUpdates([packet], metadataUpdates: updates, source: .live)

        // The packet was just appended, so the back-fill applies in place but doesn't surface as
        // a separate metadata mutation — visible identity for the new row is already correct.
        #expect(state.lastMutation == .append(0..<1))
        #expect(state.packets.first?.sniDomainName == "api.example.com")
    }

    @Test func appendAndApplyMetadataUpdatesEmitsCombinedCaseForOlderPackets() {
        var state = PacketIngestState.empty
        let firstPacket = makePacket(packetNumber: 1)
        state.append([firstPacket], source: .live)
        let secondPacket = makePacket(packetNumber: 2)
        let updates = [
            PacketMetadataUpdate(
                packetIDs: [firstPacket.id],
                sniDomainName: "api.example.com",
                client: nil,
                direction: nil
            )
        ]

        state.appendAndApplyMetadataUpdates([secondPacket], metadataUpdates: updates, source: .live)

        if case let .appendWithMetadataUpdates(range, ids) = state.lastMutation {
            #expect(range == 1..<2)
            #expect(ids == [firstPacket.id])
        } else {
            Issue.record("expected .appendWithMetadataUpdates, got \(state.lastMutation)")
        }
        #expect(state.packets.first?.sniDomainName == "api.example.com")
    }

    @Test func standaloneApplyMetadataUpdatesEmitsMetadataUpdateWithIDs() {
        var state = PacketIngestState.empty
        let packet = makePacket(packetNumber: 1)
        state.append([packet], source: .live)

        state.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [packet.id],
                sniDomainName: "api.example.com",
                client: nil,
                direction: nil
            )
        ])

        if case let .metadataUpdate(ids) = state.lastMutation {
            #expect(ids == [packet.id])
        } else {
            Issue.record("expected .metadataUpdate, got \(state.lastMutation)")
        }
    }

    @Test func appendAndApplyMetadataUpdatesIsNoOpForEmptyInputs() {
        var state = PacketIngestState.empty
        state.appendAndApplyMetadataUpdates([], metadataUpdates: [], source: .live)

        #expect(state.lastMutation == .none)
        #expect(state.packets.isEmpty)
    }

    @Test func applySummaryUpdatesRefreshesProtocolAndInfoInPlace() {
        var state = PacketIngestState.empty
        let packet = makePacket(packetNumber: 1)
        state.append([packet], source: .live)

        state.applySummaryUpdates([
            PacketSummaryUpdate(packetID: packet.id, protocolSummary: "TLSv1.3", infoSummary: "Client Hello")
        ])

        #expect(state.packets.first?.protocolSummary == "TLSv1.3")
        #expect(state.packets.first?.infoSummary == "Client Hello")
        if case let .metadataUpdate(ids) = state.lastMutation {
            #expect(ids == [packet.id])
        } else {
            Issue.record("expected .metadataUpdate, got \(state.lastMutation)")
        }
    }

    @Test func textStyleMutationsUpdateOnlyIndexedPacketsAndComposeEffects() {
        var state = PacketIngestState.empty
        let packets = (1...3).map { makePacket(packetNumber: UInt64($0)) }
        state.append(packets, source: .live)

        let coloredIDs = state.applyTextStyleMutation(.setHighlightColor(.red), packetIDs: [1, 3, 99])

        #expect(coloredIDs == [1, 3])
        #expect(state.packets[0].resolvedTextStyle == PacketTextStyle(highlightColor: .red))
        #expect(state.packets[1].resolvedTextStyle == .plain)
        #expect(state.packets[2].resolvedTextStyle == PacketTextStyle(highlightColor: .red))
        #expect(state.lastMutation == .metadataUpdate(packetIDs: [1, 3]))

        state.applyTextStyleMutation(.toggleStrikethrough, packetIDs: [1])
        #expect(state.packets[0].resolvedTextStyle == PacketTextStyle(highlightColor: .red, isStrikethrough: true))

        state.applyTextStyleMutation(.reset, packetIDs: [3])
        #expect(state.packets[2].resolvedTextStyle == .plain)
        #expect(state.packets[2].textStyle == nil)
    }

    @Test func commentMutationUpdatesOnlyIndexedPackets() {
        var state = PacketIngestState.empty
        let packets = (1...3).map { makePacket(packetNumber: UInt64($0)) }
        state.append(packets, source: .live)

        let updatedIDs = state.setCustomComment("\n Review this packet \n", packetIDs: [1, 3, 99])

        #expect(updatedIDs == [1, 3])
        #expect(state.packets[0].customComment == "Review this packet")
        #expect(state.packets[1].customComment == nil)
        #expect(state.packets[2].customComment == "Review this packet")
        #expect(state.lastMutation == .metadataUpdate(packetIDs: [1, 3]))
    }

    private func makePacket(packetNumber: UInt64) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .live,
            interfaceID: "en0",
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: 42,
            infoSummary: "Packet \(packetNumber)",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }
}

private final class FakeTCPViewerCore: TCPViewerCoreProviding, @unchecked Sendable {
    private let interfaceInventories: [[CaptureInterfaceSummary]]
    private let liveSession: FakeLiveSession
    private let documentFactory: (URL) -> FakeOfflineDocument
    private let captureFilterValidator: (String) -> CaptureFilterValidation
    private(set) var interfaceCallCount = 0

    private(set) var liveSessionRequests: [(interfaceID: String, options: CaptureOptions)] = []
    private(set) var openedDocumentURLs: [URL] = []

    init(
        interfaceInventories: [[CaptureInterfaceSummary]],
        liveSession: FakeLiveSession = FakeLiveSession(),
        documentFactory: @escaping (URL) -> FakeOfflineDocument = { url in
            FakeOfflineDocument(
                url: url,
                metadata: CaptureDocumentMetadata(format: .pcapng),
                openPlan: .completed([])
            )
        },
        captureFilterValidator: @escaping (String) -> CaptureFilterValidation = { expression in
            let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            return CaptureFilterValidation(
                disposition: trimmed.isEmpty ? .invalid : .valid,
                normalizedExpression: trimmed.isEmpty ? nil : trimmed,
                message: trimmed.isEmpty ? "Capture filters cannot be empty." : nil
            )
        }
    ) {
        self.interfaceInventories = interfaceInventories
        self.liveSession = liveSession
        self.documentFactory = documentFactory
        self.captureFilterValidator = captureFilterValidator
    }

    func listInterfaces(completion: @escaping TCPViewerCompletion<[CaptureInterfaceSummary]>) {
        guard !interfaceInventories.isEmpty else {
            completion(.success([]))
            return
        }

        let index = min(interfaceCallCount, interfaceInventories.count - 1)
        interfaceCallCount += 1
        completion(.success(interfaceInventories[index]))
    }

    func validateCaptureFilter(_ expression: String, completion: @escaping (CaptureFilterValidation) -> Void) {
        completion(captureFilterValidator(expression))
    }

    func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions {
        try options.validated(for: interface)
    }

    func makeLiveCaptureSession(
        interfaceID: String,
        options: CaptureOptions,
        completion: @escaping TCPViewerCompletion<any LiveCaptureSessionProviding>
    ) {
        liveSessionRequests.append((interfaceID: interfaceID, options: options))
        completion(.success(liveSession))
    }

    func supportedOfflineFormats() -> [CaptureFileFormat] {
        [.pcap, .pcapng]
    }

    func openOfflineCaptureDocument(
        at fileURL: URL,
        completion: @escaping TCPViewerCompletion<any OfflineCaptureDocumentProviding>
    ) {
        openedDocumentURLs.append(fileURL)
        completion(.success(documentFactory(fileURL)))
    }

    func loadPacketSummaries(from fileURL: URL, completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        documentFactory(fileURL).open(completion: completion)
    }
}

private final class FakeLiveSession: LiveCaptureSessionProviding, @unchecked Sendable {
    var eventHandler: PacketIngestEventHandler?

    var inspections: [PacketSummary.ID: PacketInspection] = [:]
    var inspectionGate: AsyncGate?
    var exportGate: AsyncGate?
    var stopError: Error?
    private(set) var startCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var clearCapturedPacketsCount = 0
    private(set) var exportRequests: [([PacketSummary.ID], URL, CaptureFileFormat)] = []
    private(set) var latestHealthSnapshot = CaptureHealthSnapshot.empty

    func start(completion: @escaping TCPViewerVoidCompletion) {
        startCount += 1
        completion(.success(()))
    }

    func pause(completion: @escaping TCPViewerVoidCompletion) {
        pauseCount += 1
        completion(.success(()))
    }

    func resume(completion: @escaping TCPViewerVoidCompletion) {
        resumeCount += 1
        completion(.success(()))
    }

    func stop(completion: @escaping TCPViewerVoidCompletion) {
        stopCount += 1
        if let stopError {
            completion(.failure(stopError))
            return
        }
        completion(.success(()))
    }

    func clearCapturedPackets(completion: @escaping TCPViewerVoidCompletion) {
        clearCapturedPacketsCount += 1
        latestHealthSnapshot = .empty
        completion(.success(()))
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        guard let inspection = inspections[id] else {
            completion(.failure(TCPViewerCoreError(code: .liveSessionControlFailed, message: "Missing inspection for packet \(id).")))
            return
        }
        if let inspectionGate { inspectionGate.wait { completion(.success(inspection)) } }
        else { completion(.success(inspection)) }
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        if shouldCancel?() == true {
            completion(.failure(TCPViewerCoreError(code: .operationCancelled, message: "Packet export was cancelled.")))
            return
        }

        progress?(PacketExportProgress(exportedPacketCount: identifiers.count, totalPacketCount: identifiers.count))
        exportRequests.append((identifiers, url, format))
        if let exportGate { exportGate.wait { completion(.success(())) } }
        else { completion(.success(())) }
    }

    func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void) {
        completion(latestHealthSnapshot)
    }

    func send(_ event: PacketIngestEvent) {
        if case .healthChanged(let health) = event {
            latestHealthSnapshot = health
        }
        eventHandler?(.success(event))
    }
}

private final class FakeTCPViewSessionExportWriter: TCPViewSessionExportWriting, @unchecked Sendable {
    struct Request {
        let snapshot: TCPViewSessionExportSnapshot
        let captureFileURL: URL
        let destinationURL: URL
    }

    private let lock = NSLock()
    private var storedRequests: [Request] = []
    var error: Error?

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func writePackage(
        snapshot: TCPViewSessionExportSnapshot,
        captureFileURL: URL,
        to destinationURL: URL,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?
    ) throws {
        if shouldCancel?() == true {
            throw TCPViewerCoreError(code: .operationCancelled, message: "TCPViewer session export was cancelled.")
        }
        if let error {
            throw error
        }

        progress?(PacketExportProgress(
            exportedPacketCount: snapshot.packets.count + 6,
            totalPacketCount: snapshot.packets.count + 6
        ))
        lock.lock()
        storedRequests.append(Request(snapshot: snapshot, captureFileURL: captureFileURL, destinationURL: destinationURL))
        lock.unlock()
    }
}

private final class FakeOfflineDocument: OfflineCaptureDocumentProviding, @unchecked Sendable {
    struct LoadPlan {
        var batches: [[PacketSummary]]
        var progress: [PacketLoadProgress]
        var error: TCPViewerCoreError?
        var gate: AsyncGate? = nil

        static func completed(_ packets: [PacketSummary]) -> LoadPlan {
            LoadPlan(
                batches: packets.isEmpty ? [] : [packets],
                progress: [],
                error: nil,
                gate: nil
            )
        }
    }

    var eventHandler: PacketIngestEventHandler?

    private(set) var url: URL
    private(set) var metadata: CaptureDocumentMetadata
    private(set) var packets: [PacketSummary] = []
    private let openPlan: LoadPlan
    private let reopenPlan: LoadPlan
    private let inspections: [PacketSummary.ID: PacketInspection]
    private let displayFilterMatchesByExpression: [String: Set<PacketSummary.ID>]
    private var displayFilterExpressionByGeneration: [UInt64: String] = [:]

    var filterEvaluationGate: AsyncGate?
    private(set) var displayFilterActivationGenerations: [UInt64] = []
    private(set) var saveCount = 0
    private(set) var saveAsRequests: [(URL, CaptureFileFormat)] = []
    private(set) var exportRequests: [([PacketSummary.ID], URL, CaptureFileFormat)] = []
    private(set) var cancelLoadingCount = 0
    private(set) var currentProgress: PacketLoadProgress = .idle
    private(set) var displayFilterEvaluationRequests: [[PacketSummary.ID]] = []

    init(
        url: URL,
        metadata: CaptureDocumentMetadata,
        openPlan: LoadPlan,
        reopenPlan: LoadPlan? = nil,
        inspections: [PacketSummary.ID: PacketInspection] = [:],
        displayFilterMatchesByExpression: [String: Set<PacketSummary.ID>] = [:]
    ) {
        self.url = url
        self.metadata = metadata
        self.openPlan = openPlan
        self.reopenPlan = reopenPlan ?? openPlan
        self.inspections = inspections
        self.displayFilterMatchesByExpression = displayFilterMatchesByExpression
    }

    func open(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        run(openPlan, verb: "Loaded", completion: completion)
    }

    func reopen(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        run(reopenPlan, verb: "Reloaded", completion: completion)
    }

    func cancelLoading(completion: (() -> Void)?) {
        cancelLoadingCount += 1
        completion?()
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        if let inspection = inspections[id] {
            completion(.success(inspection))
            return
        }

        guard let packet = packets.first(where: { $0.id == id }) else {
            completion(.failure(TCPViewerCoreError(code: .offlineFileOpenFailed, message: "Missing packet \(id).")))
            return
        }

        completion(.success(PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data(repeating: 0xAB, count: 32),
            detailNodes: [
                PacketDetailNode(id: "frame", name: "Frame", value: "Packet \(packet.packetNumber)", kind: .layer)
            ],
            decodeStatus: packet.decodeStatus
        )))
    }

    func activateDisplayFilter(
        _ expression: String,
        generation: UInt64,
        completion: @escaping (DisplayFilterValidation) -> Void
    ) {
        displayFilterActivationGenerations.append(generation)
        displayFilterExpressionByGeneration[generation] = expression
        completion(DisplayFilterValidation(normalizedExpression: expression, status: .valid))
    }

    func evaluateDisplayFilter(
        packetIDs: [PacketSummary.ID],
        generation: UInt64,
        completion: @escaping TCPViewerCompletion<DisplayFilterMatchBatch>
    ) {
        displayFilterEvaluationRequests.append(packetIDs)
        let expression = displayFilterExpressionByGeneration[generation] ?? ""
        let matchingIDs = displayFilterMatchesByExpression[expression] ?? []
        let batch = DisplayFilterMatchBatch(
            generation: generation,
            evaluatedPacketIDs: packetIDs,
            matchingPacketIDs: packetIDs.filter(matchingIDs.contains)
        )
        if let filterEvaluationGate { filterEvaluationGate.wait { completion(.success(batch)) } }
        else { completion(.success(batch)) }
    }

    func clearDisplayFilter(completion: @escaping TCPViewerVoidCompletion) {
        displayFilterExpressionByGeneration.removeAll()
        completion(.success(()))
    }

    func save(completion: @escaping TCPViewerVoidCompletion) {
        if currentProgress.isPartialResult {
            completion(.failure(TCPViewerCoreError(
                code: .offlineFileSaveFailed,
                message: "TCP Viewer cannot save a partially loaded capture. Reload the file to finish loading first."
            )))
            return
        }

        saveCount += 1
        send(.documentMetadataChanged(metadata))
        send(.documentStateChanged(phase: .saved, message: "Saved \(url.lastPathComponent)."))
        completion(.success(()))
    }

    func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        if currentProgress.isPartialResult {
            completion(.failure(TCPViewerCoreError(
                code: .offlineFileSaveFailed,
                message: "TCP Viewer cannot save a partially loaded capture. Reload the file to finish loading first."
            )))
            return
        }

        saveAsRequests.append((url, format))
        self.url = url
        metadata = CaptureDocumentMetadata(
            format: format,
            operatingSystem: format == .pcapng ? metadata.operatingSystem : nil,
            hardware: format == .pcapng ? metadata.hardware : nil,
            captureApplication: format == .pcapng ? metadata.captureApplication : nil,
            fileComment: format == .pcapng ? metadata.fileComment : nil
        )

        send(.documentMetadataChanged(metadata))
        send(.documentStateChanged(phase: .saved, message: "Saved as \(url.lastPathComponent)."))
        completion(.success(()))
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        if shouldCancel?() == true {
            completion(.failure(TCPViewerCoreError(code: .operationCancelled, message: "Packet export was cancelled.")))
            return
        }

        let knownIDs = Set(packets.map(\.id))
        guard identifiers.allSatisfy({ knownIDs.contains($0) }) else {
            completion(.failure(TCPViewerCoreError(code: .offlineFileSaveFailed, message: "Missing packet export backing.")))
            return
        }

        progress?(PacketExportProgress(exportedPacketCount: identifiers.count, totalPacketCount: identifiers.count))
        exportRequests.append((identifiers, url, format))
        if url.path.contains("SessionCaptureParts") {
            try? Data("pcapng-part-\(identifiers.map(String.init).joined(separator: ","))".utf8).write(to: url)
        }
        completion(.success(()))
    }

    func currentURL() -> URL {
        url
    }

    func currentMetadata() -> CaptureDocumentMetadata {
        metadata
    }

    func packetSummaries() -> [PacketSummary] {
        packets
    }

    func loadProgress() -> PacketLoadProgress {
        currentProgress
    }

    private func run(_ plan: LoadPlan, verb: String, completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        packets = []
        currentProgress = PacketLoadProgress(
            phase: .loading,
            loadedPacketCount: 0,
            message: "\(verb == "Loaded" ? "Opening" : "Reopening") \(url.lastPathComponent)..."
        )

        send(.documentMetadataChanged(metadata))
        send(.packetBatch([], disposition: .replace))
        if let gate = plan.gate {
            gate.wait { [weak self] in
                self?.finishRun(plan, verb: verb, completion: completion)
            }
            return
        }

        finishRun(plan, verb: verb, completion: completion)
    }

    private func finishRun(_ plan: LoadPlan, verb: String, completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        for (index, batch) in plan.batches.enumerated() {
            packets.append(contentsOf: batch)
            send(.packetBatch(batch, disposition: .append))

            if index < plan.progress.count {
                currentProgress = plan.progress[index]
                send(.loadProgressChanged(currentProgress))
            }
        }

        if let error = plan.error {
            if plan.progress.isEmpty {
                currentProgress = PacketLoadProgress(
                    phase: error.code == .operationCancelled ? .cancelled : .failed,
                    loadedPacketCount: packets.count,
                    isPartialResult: !packets.isEmpty,
                    message: error.message
                )
                send(.loadProgressChanged(currentProgress))
            }
            completion(.failure(error))
            return
        }

        if currentProgress.phase != .completed {
            currentProgress = PacketLoadProgress(
                phase: .completed,
                loadedPacketCount: packets.count,
                isPartialResult: false,
                message: "\(verb) \(packets.count) packets from \(url.lastPathComponent)."
            )
            send(.loadProgressChanged(currentProgress))
        }

        send(.documentStateChanged(phase: .loaded, message: currentProgress.message))
        completion(.success(packets))
    }

    func send(_ event: PacketIngestEvent) {
        eventHandler?(.success(event))
    }
}

private final class AsyncGate {
    private var isOpen = false
    private var continuations: [() -> Void] = []

    func wait(_ completion: @escaping () -> Void) {
        if isOpen {
            completion()
            return
        }

        continuations.append(completion)
    }

    func open() async {
        isOpen = true
        let waitingContinuations = continuations
        continuations.removeAll()
        waitingContinuations.forEach { $0() }
    }
}

private final class WeakTabTestObject {
    weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }

    var typeName: String? {
        object.map { String(reflecting: type(of: $0)) }
    }
}

private final class WorkspaceFakePacketClientResolver: PacketClientResolving {
    private let client: PacketClient?

    init(client: PacketClient?) {
        self.client = client
    }

    func reset() {}

    func client(for packet: PacketSummary) -> PacketClient? {
        client
    }
}
