//
//  TCPViewerWorkspaceTabContentController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import AppKit

/// Owns one tab's root controllers and lazily adds at most one side-by-side pane.
final class TCPViewerWorkspaceTabContentController: NSViewController {
    private let splitView = NSSplitView()
    private(set) var firstPane: TCPViewerRootViewController?
    private(set) var secondPane: TCPViewerRootViewController?
    private(set) var focusedPane: TCPViewerRootViewController?
    private(set) var isActive = true

    var panes: [TCPViewerRootViewController] {
        [firstPane, secondPane].compactMap { $0 }
    }

    var isSplitViewVisible: Bool { secondPane != nil }

    init(pane: TCPViewerRootViewController) {
        firstPane = pane
        focusedPane = pane
        super.init(nibName: nil, bundle: nil)
        pane.setFocusedPane(true, showsOutline: false)
    }

    required init?(coder: NSCoder) { fatalError("Use init(pane:)") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.frame = view.bounds
        splitView.autoresizingMask = [.width, .height]
        view.addSubview(splitView)
        panes.forEach(attachPane)
        equalizePanes()
    }

    @discardableResult
    func showSecondPane(using factory: () -> TCPViewerRootViewController) -> TCPViewerRootViewController {
        if let secondPane {
            focus(secondPane)
            return secondPane
        }

        let pane = factory()
        pane.setFocusedPane(false, showsOutline: true)
        firstPane?.viewModel.showInspectorForSplitView()
        pane.viewModel.showInspectorForSplitView()
        secondPane = pane
        if isViewLoaded {
            attachPane(pane)
            equalizePanes()
        }
        if isActive {
            pane.activate()
        } else {
            pane.deactivate()
        }
        focus(pane)
        return pane
    }

    func removeSecondPane() {
        guard let secondPane, let firstPane else { return }
        focus(firstPane)
        if isViewLoaded {
            splitView.removeArrangedSubview(secondPane.view)
            secondPane.view.removeFromSuperview()
        }
        self.secondPane = nil
        secondPane.close()
        firstPane.setFocusedPane(true, showsOutline: false)
    }

    func focus(_ pane: TCPViewerRootViewController) {
        guard panes.contains(where: { $0 === pane }), focusedPane !== pane else { return }
        focusedPane = pane
        panes.forEach { $0.setFocusedPane($0 === pane, showsOutline: isSplitViewVisible) }
    }

    func pane(containing responder: NSResponder?) -> TCPViewerRootViewController? {
        var current = responder
        while let candidate = current {
            if let candidateView = candidate as? NSView,
               let pane = panes.first(where: { pane in
                   pane.isViewLoaded && (candidateView === pane.view || candidateView.isDescendant(of: pane.view))
               }) {
                return pane
            }
            if let controller = candidate as? NSViewController,
               let pane = panes.first(where: { $0 === controller }) {
                return pane
            }
            current = candidate.nextResponder
        }
        return nil
    }

    func activate() {
        guard !isActive else {
            panes.forEach { $0.activate() }
            return
        }
        isActive = true
        panes.forEach { $0.activate() }
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        panes.forEach { $0.deactivate() }
    }

    // Detach before releasing both panes so AppKit cannot retain either responder tree.
    func close() {
        let closingPanes = panes
        focusedPane = nil
        firstPane = nil
        secondPane = nil
        closingPanes.forEach { pane in
            if isViewLoaded {
                splitView.removeArrangedSubview(pane.view)
                pane.view.removeFromSuperview()
            }
            pane.close()
        }
        splitView.delegate = nil
        if isViewLoaded { view.removeFromSuperview() }
        removeFromParent()
    }

    private func attachPane(_ pane: TCPViewerRootViewController) {
        addChild(pane)
        pane.view.autoresizingMask = [.width, .height]
        splitView.addArrangedSubview(pane.view)
    }

    private func equalizePanes() {
        guard splitView.arrangedSubviews.count == 2 else { return }
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition((splitView.bounds.width - splitView.dividerThickness) / 2, ofDividerAt: 0)
    }
}

extension TCPViewerWorkspaceTabContentController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard dividerIndex == 0, splitView.arrangedSubviews.count == 2 else { return proposedPosition }
        let availableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
        let minimumWidth = min(300, availableWidth / 2)
        return min(max(proposedPosition, minimumWidth), availableWidth - minimumWidth)
    }
}

#if DEBUG
extension TCPViewerWorkspaceTabContentController {
    var splitViewForTesting: NSSplitView { splitView }
}
#endif
