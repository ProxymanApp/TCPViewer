import AppKit
import PcapPlusPlusCore

protocol StatusStripViewControllerDelegate: AnyObject {
    func statusStripViewControllerDidRequestCancelLoad(_ controller: StatusStripViewController)
}

final class StatusStripViewModel {
    private(set) var accessTitle = "Checking Capture Access"
    private(set) var accessImageName = "bolt.horizontal.circle"
    private(set) var accessColor = NSColor.secondaryLabelColor
    private(set) var sessionText = "Idle"
    private(set) var messageText = "No packets loaded yet."
    private(set) var packetCountText = "0 packets"
    private(set) var malformedCountText = "0 malformed"
    private(set) var droppedCountText = "0 dropped"
    private(set) var malformedColor = NSColor.secondaryLabelColor
    private(set) var droppedColor = NSColor.secondaryLabelColor
    private(set) var canCancelLoad = false

    // Build the compact bottom status strip from the current packet/capture snapshot.
    func render(snapshot: NetworkInspectorSnapshot) {
        accessTitle = snapshot.base.accessState.title
        accessImageName = imageName(for: snapshot.base.accessState)
        accessColor = snapshot.base.accessState.isCaptureReady ? .systemGreen : .secondaryLabelColor
        sessionText = snapshot.base.sessionState.phase.rawValue.capitalized
        packetCountText = "\(snapshot.totalPacketCount) packets"
        malformedCountText = "\(snapshot.malformedPacketCount) malformed"
        droppedCountText = "\(snapshot.droppedPacketCount) dropped"
        malformedColor = snapshot.malformedPacketCount > 0 ? .systemOrange : .secondaryLabelColor
        droppedColor = snapshot.droppedPacketCount > 0 ? .systemOrange : .secondaryLabelColor
        canCancelLoad = snapshot.base.loadState.canCancel

        if snapshot.base.loadState.progress.phase == .loading {
            messageText = snapshot.base.loadState.progress.message
        } else if snapshot.base.documentState.isPartialResult {
            messageText = "Partial Load"
        } else {
            messageText = snapshot.base.packetIngestState.statusMessage
        }
    }

    private func imageName(for state: CaptureAccessState) -> String {
        switch state {
        case .ready:
            "checkmark.circle.fill"
        case .blocked:
            "exclamationmark.triangle.fill"
        case .checking, .recovering, .unknown:
            "bolt.horizontal.circle"
        }
    }
}

final class StatusStripViewController: NSViewController {
    weak var delegate: StatusStripViewControllerDelegate?

    private let viewModel = StatusStripViewModel()
    private let accessImageView = NSImageView()
    private let accessLabel = PacketmanUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize))
    private let sessionLabel = PacketmanUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
    private let messageLabel = PacketmanUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
    private let cancelButton = NSButton(title: "Cancel Load", target: nil, action: nil)
    private let packetCountLabel = PacketmanUI.label("", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), color: .secondaryLabelColor)
    private let malformedLabel = PacketmanUI.label("", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), color: .secondaryLabelColor)
    private let droppedLabel = PacketmanUI.label("", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), color: .secondaryLabelColor)

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
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        viewModel.render(snapshot: snapshot)
        accessImageView.image = PacketmanUI.image(viewModel.accessImageName)
        accessImageView.contentTintColor = viewModel.accessColor
        accessLabel.stringValue = viewModel.accessTitle
        accessLabel.textColor = viewModel.accessColor
        sessionLabel.stringValue = viewModel.sessionText
        messageLabel.stringValue = viewModel.messageText
        cancelButton.isHidden = !viewModel.canCancelLoad
        packetCountLabel.stringValue = viewModel.packetCountText
        malformedLabel.stringValue = viewModel.malformedCountText
        malformedLabel.textColor = viewModel.malformedColor
        droppedLabel.stringValue = viewModel.droppedCountText
        droppedLabel.textColor = viewModel.droppedColor
    }

    private func setupLayout() {
        accessImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        accessImageView.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small

        let accessStack = NSStackView(views: [accessImageView, accessLabel])
        accessStack.orientation = .horizontal
        accessStack.alignment = .centerY
        accessStack.spacing = 5

        let spacer = NSView()
        let stack = NSStackView(views: [
            accessStack,
            sessionLabel,
            messageLabel,
            spacer,
            cancelButton,
            packetCountLabel,
            malformedLabel,
            droppedLabel,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let separator = PacketmanUI.separator()
        view.addSubview(separator)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 33),
            accessImageView.widthAnchor.constraint(equalToConstant: 14),
            accessImageView.heightAnchor.constraint(equalToConstant: 14),
            messageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: view.topAnchor),

            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func cancelLoad(_ sender: Any?) {
        delegate?.statusStripViewControllerDidRequestCancelLoad(self)
    }
}
