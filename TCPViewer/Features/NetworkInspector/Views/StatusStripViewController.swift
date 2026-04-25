import AppKit
import PcapPlusPlusCore

protocol StatusStripViewControllerDelegate: AnyObject {
    func statusStripViewControllerDidRequestCancelLoad(_ controller: StatusStripViewController)
    func statusStripViewControllerDidRequestClearPackets(_ controller: StatusStripViewController)
}

final class StatusStripViewModel {
    private(set) var totalText = "0 packets"
    private(set) var statusText = "Idle"
    private(set) var statusImageName = "circle"
    private(set) var statusColor = NSColor.secondaryLabelColor
    private(set) var canCancelLoad = false
    private(set) var canClear = false

    // Build the compact bottom status strip from the current packet/capture snapshot.
    func render(snapshot: NetworkInspectorSnapshot) {
        let packetCount = snapshot.totalPacketCount
        totalText = packetCount == 1 ? "1 packet" : "\(packetCount) packets"
        canCancelLoad = snapshot.base.loadState.canCancel
        canClear = packetCount > 0 && !canCancelLoad

        let phase = snapshot.base.sessionState.phase
        statusText = title(for: phase)
        statusImageName = imageName(for: phase)
        statusColor = color(for: phase)
    }

    private func title(for phase: CaptureSessionState.Phase) -> String {
        switch phase {
        case .idle: "Idle"
        case .ready: "Ready"
        case .starting: "Starting"
        case .running: "Active"
        case .paused: "Paused"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    private func imageName(for phase: CaptureSessionState.Phase) -> String {
        switch phase {
        case .running: "dot.radiowaves.left.and.right"
        case .starting, .stopping: "bolt.horizontal.circle"
        case .paused: "pause.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "circle"
        }
    }

    private func color(for phase: CaptureSessionState.Phase) -> NSColor {
        switch phase {
        case .running: .systemGreen
        case .paused: .systemOrange
        case .failed: .systemRed
        case .ready: .systemGreen
        case .starting, .stopping, .stopped, .idle: .secondaryLabelColor
        }
    }
}

final class StatusStripViewController: NSViewController {
    weak var delegate: StatusStripViewControllerDelegate?

    private let viewModel = StatusStripViewModel()
    private let cancelButton = NSButton(title: "Cancel Load", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let totalLabel = TCPViewerUI.label(
        "",
        font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        color: .secondaryLabelColor
    )
    private let statusImageView = NSImageView()
    private let statusLabel = TCPViewerUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize))

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        cancelButton.target = self
        cancelButton.action = #selector(cancelLoad(_:))
        clearButton.target = self
        clearButton.action = #selector(clearPackets(_:))
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        viewModel.render(snapshot: snapshot)
        cancelButton.isHidden = !viewModel.canCancelLoad
        clearButton.isHidden = viewModel.canCancelLoad
        clearButton.isEnabled = viewModel.canClear
        totalLabel.stringValue = viewModel.totalText
        statusLabel.stringValue = viewModel.statusText
        statusLabel.textColor = viewModel.statusColor
        statusImageView.image = TCPViewerUI.image(viewModel.statusImageName)
        statusImageView.contentTintColor = viewModel.statusColor
    }

    private func setupLayout() {
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small

        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.image = TCPViewerUI.image("trash")
        clearButton.imagePosition = .imageLeading

        totalLabel.alignment = .center

        statusImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        statusImageView.translatesAutoresizingMaskIntoConstraints = false

        let statusStack = NSStackView(views: [statusImageView, statusLabel])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 5

        let leadingSpacer = NSView()
        let trailingSpacer = NSView()
        leadingSpacer.translatesAutoresizingMaskIntoConstraints = false
        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            cancelButton,
            clearButton,
            leadingSpacer,
            totalLabel,
            trailingSpacer,
            statusStack,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let separator = TCPViewerUI.separator()
        view.addSubview(separator)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 33),
            statusImageView.widthAnchor.constraint(equalToConstant: 14),
            statusImageView.heightAnchor.constraint(equalToConstant: 14),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: view.topAnchor),

            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            leadingSpacer.widthAnchor.constraint(equalTo: trailingSpacer.widthAnchor),
        ])
    }

    @objc private func cancelLoad(_ sender: Any?) {
        delegate?.statusStripViewControllerDidRequestCancelLoad(self)
    }

    @objc private func clearPackets(_ sender: Any?) {
        delegate?.statusStripViewControllerDidRequestClearPackets(self)
    }
}
