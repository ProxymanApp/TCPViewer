import AppKit

struct PacketInspectorRenderState: Equatable {
    let title: String
    let imageName: String
    let message: String

    init(
        title: String = "Inspector Panel",
        imageName: String = "sidebar.trailing",
        message: String = "A redesigned inspector is coming soon."
    ) {
        self.title = title
        self.imageName = imageName
        self.message = message
    }

    init(snapshot _: NetworkInspectorSnapshot) {
        self.init()
    }
}

final class PacketInspectorPanelViewModel {
    private(set) var state = PacketInspectorRenderState()
    private var hasRendered = false

    // Keep the inspector render model stable while the panel is awaiting its redesign.
    @discardableResult
    func render(snapshot: NetworkInspectorSnapshot) -> Bool {
        let nextState = PacketInspectorRenderState(snapshot: snapshot)
        guard hasRendered else {
            state = nextState
            hasRendered = true
            return true
        }

        guard nextState != state else {
            return false
        }

        state = nextState
        return true
    }
}

final class PacketInspectorViewController: NSViewController {
    private let viewModel = PacketInspectorPanelViewModel()
    private var emptyStateView: NSView?

    init(configuration _: AppConfiguration) {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    // Render only the temporary empty state until the redesigned inspector is implemented.
    func render(snapshot: NetworkInspectorSnapshot) {
        let didChange = viewModel.render(snapshot: snapshot)
        guard didChange || emptyStateView == nil else {
            return
        }

        showEmptyState()
    }

    private func showEmptyState() {
        emptyStateView?.removeFromSuperview()
        let state = viewModel.state
        let placeholder = TCPViewerUI.placeholder(
            title: state.title,
            imageName: state.imageName,
            message: state.message,
            iconTitleSpacing: 18
        )
        TCPViewerUI.pin(placeholder, to: view)
        emptyStateView = placeholder
    }
}
