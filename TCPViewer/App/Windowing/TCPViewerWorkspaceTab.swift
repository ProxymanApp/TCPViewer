//
//  TCPViewerWorkspaceTab.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import AppKit

/// A tab retains metadata and a source; its pane is created only on first selection.
final class TCPViewerWorkspaceTab {
    let primaryPaneID = UUID()
    private(set) var secondaryPaneID: UUID?
    private var storedFocusedPaneID: UUID?
    private(set) var primaryModel: NetworkInspectorViewModel?
    private(set) var secondaryModel: NetworkInspectorViewModel?
    let id: UUID
    let title: String?
    private(set) var source: TCPViewerCaptureWorkspace?
    private(set) var contentController: TCPViewerWorkspaceTabContentController?
    var pane: TCPViewerRootViewController? { contentController?.focusedPane }
    var firstPane: TCPViewerRootViewController? { contentController?.firstPane }
    var secondPane: TCPViewerRootViewController? { contentController?.secondPane }
    var isSplitViewVisible: Bool { secondaryPaneID != nil }
    var focusedPaneID: UUID {
        if let contentController {
            return contentController.focusedPane === contentController.secondPane ? secondaryPaneID ?? primaryPaneID : primaryPaneID
        }
        return storedFocusedPaneID ?? primaryPaneID
    }

    // Keep command state lightweight until a tab is explicitly selected.
    func automationModel(id: UUID, factory: (TCPViewerCaptureWorkspace, NetworkInspectorPaneState?) -> NetworkInspectorViewModel) -> NetworkInspectorViewModel? {
        guard !isClosed, let source else { return nil }
        if id == primaryPaneID {
            if let model = firstPane?.viewModel ?? primaryModel { return model }
            let model = factory(source, nil)
            model.deactivate()
            primaryModel = model
            return model
        }
        guard id == secondaryPaneID else { return nil }
        if let model = secondPane?.viewModel ?? secondaryModel { return model }
        guard let first = automationModel(id: primaryPaneID, factory: factory) else { return nil }
        var state = first.makeSplitPaneState()
        state.inspectorPlacement = .bottom
        state.isInspectorVisible = true
        let model = factory(source, state)
        model.deactivate()
        secondaryModel = model
        return model
    }

    func enableAutomationSplit() {
        if secondaryPaneID == nil { secondaryPaneID = UUID() }
    }

    func setAutomationFocus(_ id: UUID) {
        storedFocusedPaneID = id
        if id == primaryPaneID, let firstPane { focus(firstPane) }
        else if id == secondaryPaneID, let secondPane { focus(secondPane) }
    }
    private(set) var isClosed = false
    private var lastLiveTitle = "All Packets"
    var sidebarNavigation: SidebarViewController.NavigationState?

    init(id: UUID = UUID(), source: TCPViewerCaptureWorkspace, title: String? = nil) {
        self.id = id
        self.source = source
        self.title = title
    }

    var isOffline: Bool { source?.kind == .offline }
    var displayTitle: String {
        if let title { return title }
        if let model = pane?.viewModel { updateAutomaticTitle(from: model) }
        return lastLiveTitle
    }

    // Retain the automatic title before an inactive command releases its temporary source list.
    func updateAutomaticTitle(from model: NetworkInspectorViewModel) {
        let snapshot = model.snapshot
        if let selectedTitle = snapshot.sourceListSnapshot.item(for: snapshot.selectedSourceListSelection)?.title {
            lastLiveTitle = selectedTitle
        }
    }

    // The factory is passed at selection time so dormant tabs retain no UI factory closure.
    func openPane(using factory: (TCPViewerCaptureWorkspace) -> TCPViewerRootViewController) -> TCPViewerRootViewController? {
        guard !isClosed, let source else { return nil }
        if let pane { return pane }
        let pane = factory(source)
        primaryModel = pane.viewModel
        contentController = TCPViewerWorkspaceTabContentController(pane: pane)
        return pane
    }

    @discardableResult
    func openSecondPane(
        using factory: (TCPViewerCaptureWorkspace, NetworkInspectorPaneState) -> TCPViewerRootViewController
    ) -> TCPViewerRootViewController? {
        guard !isClosed, let source, let contentController, let firstPane else { return nil }
        if let secondPane {
            contentController.focus(secondPane)
            return secondPane
        }
        enableAutomationSplit()
        var state = (secondaryModel ?? firstPane.viewModel).makeSplitPaneState()
        state.inspectorPlacement = .bottom
        state.isInspectorVisible = true
        let pane = contentController.showSecondPane { factory(source, state) }
        secondaryModel = pane.viewModel
        return pane
    }

    func closeSplitView() {
        contentController?.removeSecondPane()
        secondaryModel?.close()
        secondaryModel = nil
        secondaryPaneID = nil
        storedFocusedPaneID = primaryPaneID
    }

    func focus(_ pane: TCPViewerRootViewController) {
        contentController?.focus(pane)
    }

    func contains(_ pane: TCPViewerRootViewController) -> Bool {
        contentController?.panes.contains(where: { $0 === pane }) == true
    }

    func activate() {
        contentController?.activate()
    }

    func deactivate() {
        contentController?.deactivate()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        contentController?.close()
        contentController = nil
        primaryModel?.close()
        secondaryModel?.close()
        primaryModel = nil
        secondaryModel = nil
        sidebarNavigation = nil
        let releasedSource = source
        source = nil
        if let releasedSource, releasedSource.kind == .offline {
            releasedSource.close { [releasedSource] _ in _ = releasedSource }
        }
    }
}
