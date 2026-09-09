//
//  TCPViewerWorkspaceViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import AppKit

/// The shared window layout keeps the sidebar outside every tab's packet pane.
final class TCPViewerWorkspaceViewController: NSViewController {
    let sidebar = SidebarViewController()
    let tabBar = TCPViewerWorkspaceTabBar(frame: NSRect(x: 0, y: 0, width: 1000, height: 34))
    let paneHost = NSViewController()
    private let splitController = NSSplitViewController()
    private let contentController = NSViewController()
    private var tabHeight: NSLayoutConstraint!
    private var sidebarItem: NSSplitViewItem!
    private var hasRestoredSidebar = false
    private var isRestoringSidebar = false
    private weak var currentPane: TCPViewerWorkspaceTabContentController?
    var importHandler: (([URL]) -> Void)?

    override func loadView() {
        view = WorkspaceDropView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), handler: { [weak self] in
            self?.importHandler?($0)
        })
        addChild(splitController)
        splitController.splitView.isVertical = true
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = NetworkInspectorLayoutMetrics.minimumSidebarThickness
        sidebarItem.canCollapse = true
        splitController.addSplitViewItem(sidebarItem)
        contentController.view = NSView(frame: view.bounds)
        contentController.addChild(paneHost)
        paneHost.view = NSView(frame: view.bounds)
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.allowsFullHeightLayout = false
        splitController.addSplitViewItem(contentItem)
        for child in [tabBar, paneHost.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentController.view.addSubview(child)
        }
        tabHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabHeight,
            tabBar.leadingAnchor.constraint(equalTo: contentController.view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentController.view.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: contentController.view.safeAreaLayoutGuide.topAnchor),
            paneHost.view.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            paneHost.view.leadingAnchor.constraint(equalTo: contentController.view.leadingAnchor),
            paneHost.view.trailingAnchor.constraint(equalTo: contentController.view.trailingAnchor),
            paneHost.view.bottomAnchor.constraint(equalTo: contentController.view.bottomAnchor)
        ])
        splitController.view.frame = view.bounds
        splitController.view.autoresizingMask = [.width, .height]
        view.addSubview(splitController.view)
        NotificationCenter.default.addObserver(self, selector: #selector(sidebarDidResize),
                                               name: NSSplitView.didResizeSubviewsNotification, object: splitController.splitView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // The window owns sidebar geometry even when a different pane becomes active.
    @objc private func sidebarDidResize() {
        guard !isRestoringSidebar, !sidebarItem.isCollapsed else { return }
        currentPane?.focusedPane?.viewModel.rememberSidebarThickness(sidebar.view.frame.width)
    }

    // Attach one already-created pane; hidden tabs remain detached from the render hierarchy.
    func show(_ pane: TCPViewerWorkspaceTabContentController, tabCount: Int) {
        _ = view
        if currentPane !== pane {
            currentPane?.view.removeFromSuperview()
            currentPane?.removeFromParent()
            paneHost.addChild(pane)
            pane.view.frame = paneHost.view.bounds.isEmpty ? NSRect(x: 0, y: 0, width: 1000, height: 700) : paneHost.view.bounds
            pane.view.autoresizingMask = [.width, .height]
            paneHost.view.addSubview(pane.view)
            currentPane = pane
        }
        setTabCount(tabCount)
        if !hasRestoredSidebar, let model = pane.focusedPane?.viewModel {
            hasRestoredSidebar = true
            setSidebarVisible(model.prefersSidebarVisibleOnLaunch(), viewModel: model)
        }
    }

    func setTabCount(_ count: Int) {
        guard isViewLoaded else { return }
        tabBar.isHidden = count < 2
        tabHeight.constant = count < 2 ? 0 : 34
    }

    func setSidebarVisible(_ visible: Bool?, viewModel: NetworkInspectorViewModel) {
        _ = view
        isRestoringSidebar = true
        defer { isRestoringSidebar = false }
        let show = visible ?? sidebarItem.isCollapsed
        if !show { viewModel.rememberSidebarThickness(sidebar.view.frame.width) }
        sidebarItem.isCollapsed = !show
        viewModel.setSidebarVisible(show)
        if show, let width = viewModel.preferredSidebarThickness(for: view.bounds.width) {
            splitController.splitView.setPosition(width, ofDividerAt: 0)
        }
    }

    #if DEBUG
    var tabBarHeightForTesting: CGFloat { tabHeight?.constant ?? 0 }
    #endif
}

private final class WorkspaceDropView: NSView {
    private let handler: ([URL]) -> Void

    init(frame: NSRect, handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:handler:)") }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        handler(files)
        return true
    }
}
