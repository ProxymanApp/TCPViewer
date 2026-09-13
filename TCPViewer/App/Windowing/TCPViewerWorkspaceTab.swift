//
//  TCPViewerWorkspaceTab.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import AppKit

/// A tab retains metadata and a source; its pane is created only on first selection.
final class TCPViewerWorkspaceTab {
    let id: UUID
    let title: String?
    private(set) var source: TCPViewerCaptureWorkspace?
    private(set) var contentController: TCPViewerWorkspaceTabContentController?
    var pane: TCPViewerRootViewController? { contentController?.focusedPane }
    var firstPane: TCPViewerRootViewController? { contentController?.firstPane }
    var secondPane: TCPViewerRootViewController? { contentController?.secondPane }
    var isSplitViewVisible: Bool { contentController?.isSplitViewVisible == true }
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
        if let snapshot = pane?.viewModel.snapshot,
           let selectedTitle = snapshot.sourceListSnapshot.item(for: snapshot.selectedSourceListSelection)?.title {
            lastLiveTitle = selectedTitle
        }
        return lastLiveTitle
    }

    // The factory is passed at selection time so dormant tabs retain no UI factory closure.
    func openPane(using factory: (TCPViewerCaptureWorkspace) -> TCPViewerRootViewController) -> TCPViewerRootViewController? {
        guard !isClosed, let source else { return nil }
        if let pane { return pane }
        let pane = factory(source)
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
        var state = firstPane.viewModel.makeSplitPaneState()
        state.inspectorPlacement = .bottom
        state.isInspectorVisible = true
        return contentController.showSecondPane {
            factory(source, state)
        }
    }

    func closeSplitView() {
        contentController?.removeSecondPane()
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
        sidebarNavigation = nil
        let releasedSource = source
        source = nil
        if let releasedSource, releasedSource.kind == .offline {
            releasedSource.close { [releasedSource] _ in _ = releasedSource }
        }
    }
}
