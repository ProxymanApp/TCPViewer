import AppKit
import PcapPlusPlusCore

protocol PacketWorkspaceViewControllerDelegate: AnyObject {
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didSelectPacket identifier: PacketSummary.ID?)
}

final class PacketWorkspaceViewModel {
    private(set) var title = "Packets"
    private(set) var countText = "0 visible"
    private(set) var totalText: String?
    private(set) var chips: [PacketFilterChip] = []
    private(set) var isEmpty = true
    private(set) var emptyTitle = "No Packets"
    private(set) var emptyMessage = "Start a live capture or open a pcap/pcapng file."

    // Convert the root snapshot into packet-workspace-only render data.
    func render(snapshot: NetworkInspectorSnapshot) {
        countText = "\(snapshot.visiblePacketCount) visible"
        totalText = snapshot.visiblePacketCount == snapshot.totalPacketCount ? nil : "of \(snapshot.totalPacketCount)"
        chips = snapshot.displayFilterChips
        isEmpty = snapshot.packetRows.isEmpty
        emptyTitle = snapshot.totalPacketCount == 0 ? "No Packets" : "No Matching Packets"
        emptyMessage = snapshot.totalPacketCount == 0
            ? "Start a live capture or open a pcap/pcapng file."
            : "Adjust the packet filter to show packets again."
    }
}

final class PacketWorkspaceViewController: NSViewController {
    weak var delegate: PacketWorkspaceViewControllerDelegate?

    private let viewModel = PacketWorkspaceViewModel()
    private let headerView = NSView()
    private let titleLabel = PacketmanUI.label("Packets", font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
    private let countLabel = PacketmanUI.label("0 visible", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), color: .secondaryLabelColor)
    private let totalLabel = PacketmanUI.label("", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), color: .secondaryLabelColor)
    private let chipStack = NSStackView(views: [], orientation: .horizontal, spacing: 6)
    private let contentContainer = NSView()
    private let tableController = PacketTableViewController()
    private var placeholderView: NSView?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupHeader()
        setupContent()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableController.delegate = self
    }

    // Render the packet workspace and swap between the table and empty state as needed.
    func render(snapshot: NetworkInspectorSnapshot) {
        viewModel.render(snapshot: snapshot)
        titleLabel.stringValue = viewModel.title
        countLabel.stringValue = viewModel.countText
        totalLabel.stringValue = viewModel.totalText ?? ""
        totalLabel.isHidden = viewModel.totalText == nil
        renderChips(viewModel.chips)

        if viewModel.isEmpty {
            showPlaceholder(title: viewModel.emptyTitle, message: viewModel.emptyMessage)
        } else {
            showTable()
            tableController.render(snapshot: snapshot)
        }
    }

    private func setupHeader() {
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        let spacer = NSView()
        let stack = NSStackView(views: [titleLabel, countLabel, totalLabel, chipStack, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(stack)

        let separator = PacketmanUI.separator()
        headerView.addSubview(separator)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 40),

            stack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
        ])
    }

    private func setupContent() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        addChild(tableController)

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func renderChips(_ chips: [PacketFilterChip]) {
        chipStack.arrangedSubviews.forEach { view in
            chipStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for chip in chips {
            let label = PacketmanUI.label(chip.label, font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), color: .secondaryLabelColor)
            label.wantsLayer = true
            label.layer?.cornerRadius = 8
            label.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor
            label.layer?.masksToBounds = true
            label.alignment = .center
            label.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                label.heightAnchor.constraint(equalToConstant: 20),
                label.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            ])
            chipStack.addArrangedSubview(label)
        }
    }

    private func showPlaceholder(title: String, message: String) {
        if tableController.view.superview != nil {
            tableController.view.removeFromSuperview()
        }

        placeholderView?.removeFromSuperview()
        let placeholder = PacketmanUI.placeholder(title: title, imageName: "list.bullet.rectangle", message: message)
        PacketmanUI.pin(placeholder, to: contentContainer)
        placeholderView = placeholder
    }

    private func showTable() {
        placeholderView?.removeFromSuperview()
        placeholderView = nil

        if tableController.view.superview == nil {
            PacketmanUI.pin(tableController.view, to: contentContainer)
        }
    }
}

extension PacketWorkspaceViewController: PacketTableViewControllerDelegate {
    func packetTableViewController(_ controller: PacketTableViewController, didSelectPacket identifier: PacketSummary.ID?) {
        delegate?.packetWorkspaceViewController(self, didSelectPacket: identifier)
    }
}
