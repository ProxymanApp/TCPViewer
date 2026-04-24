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
    private(set) var emptyImageName = "list.bullet.rectangle"

    // Convert the root snapshot into packet-workspace-only render data.
    func render(snapshot: NetworkInspectorSnapshot) {
        countText = "\(snapshot.visiblePacketCount) visible"
        totalText = snapshot.visiblePacketCount == snapshot.totalPacketCount ? nil : "of \(snapshot.totalPacketCount)"
        chips = snapshot.displayFilterChips
        isEmpty = snapshot.packetRows.isEmpty

        switch snapshot.selectedSourceListSelection {
        case .pinned:
            emptyTitle = "Pinned Packets"
            emptyMessage = "Pinning packets is coming soon."
            emptyImageName = "pin.fill"
        case .saved:
            emptyTitle = "Saved Packets"
            emptyMessage = "Saving packets is coming soon."
            emptyImageName = "tray.and.arrow.down"
        default:
            emptyTitle = snapshot.totalPacketCount == 0 ? "No Packets" : "No Matching Packets"
            emptyMessage = snapshot.totalPacketCount == 0
                ? "Start a live capture or open a pcap/pcapng file."
                : "Adjust the packet filter to show packets again."
            emptyImageName = "list.bullet.rectangle"
        }
    }
}

final class PacketWorkspaceViewController: NSViewController {
    weak var delegate: PacketWorkspaceViewControllerDelegate?

    private let viewModel = PacketWorkspaceViewModel()
    private let contentContainer = NSView()
    private let tableController = PacketTableViewController()
    private var placeholderView: NSView?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupContent()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableController.delegate = self
    }

    // Render the packet workspace and swap between the table and empty state as needed.
    func render(snapshot: NetworkInspectorSnapshot) {
        viewModel.render(snapshot: snapshot)

        if viewModel.isEmpty {
            showPlaceholder(title: viewModel.emptyTitle, message: viewModel.emptyMessage, imageName: viewModel.emptyImageName)
        } else {
            showTable()
            tableController.render(snapshot: snapshot)
        }
    }

    private func setupContent() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        addChild(tableController)

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func showPlaceholder(title: String, message: String, imageName: String) {
        if tableController.view.superview != nil {
            tableController.view.removeFromSuperview()
        }

        placeholderView?.removeFromSuperview()
        let placeholder = PacketmanUI.placeholder(title: title, imageName: imageName, message: message)
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
