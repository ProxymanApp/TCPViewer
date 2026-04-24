import AppKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarViewController(_ controller: SidebarViewController, didSelect selection: NetworkInspectorSidebarSelection)
}

enum SidebarRow: Hashable {
    case group(String)
    case item(title: String, imageName: String, selection: NetworkInspectorSidebarSelection)

    var title: String {
        switch self {
        case .group(let title):
            title
        case .item(let title, _, _):
            title
        }
    }

    var imageName: String? {
        switch self {
        case .group:
            nil
        case .item(_, let imageName, _):
            imageName
        }
    }

    var selection: NetworkInspectorSidebarSelection? {
        switch self {
        case .group:
            nil
        case .item(_, _, let selection):
            selection
        }
    }
}

final class SidebarViewModel {
    private(set) var rows: [SidebarRow] = [
        .group("Capture"),
        .item(title: "Live Capture", imageName: "dot.radiowaves.left.and.right", selection: .liveCapture),
        .item(title: "Recent Captures", imageName: "clock", selection: .recentCaptures),
        .item(title: "Saved Sessions", imageName: "externaldrive", selection: .savedSessions),
    ]
    private(set) var selectedSidebar: NetworkInspectorSidebarSelection = .liveCapture

    // Keep source-list selection in sync with the root snapshot.
    func render(snapshot: NetworkInspectorSnapshot) {
        selectedSidebar = snapshot.selectedSidebar
    }

    func rowIndex(for selection: NetworkInspectorSidebarSelection) -> Int? {
        rows.firstIndex { $0.selection == selection }
    }
}

final class SidebarViewController: NSViewController {
    weak var delegate: SidebarViewControllerDelegate?

    private let viewModel = SidebarViewModel()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let effectView = NSVisualEffectView()
    private var isSyncingSelection = false

    override func loadView() {
        view = effectView
        setupTable()
        PacketmanUI.pin(scrollView, to: effectView)
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        viewModel.render(snapshot: snapshot)
        tableView.reloadData()
        guard let rowIndex = viewModel.rowIndex(for: snapshot.selectedSidebar) else {
            return
        }

        isSyncingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        isSyncingSelection = false
    }

    private func setupTable() {
        effectView.blendingMode = .behindWindow
        effectView.material = .sidebar
        effectView.state = .active

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .sourceList
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 28
        tableView.backgroundColor = .clear

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.rows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard viewModel.rows.indices.contains(row) else {
            return false
        }

        if case .group = viewModel.rows[row] {
            return true
        }

        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard viewModel.rows.indices.contains(row) else {
            return nil
        }

        let item = viewModel.rows[row]
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("SidebarCell"), owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        cell.textField?.removeFromSuperview()
        cell.imageView?.removeFromSuperview()

        let imageView = NSImageView()
        if let imageName = item.imageName {
            imageView.image = PacketmanUI.image(imageName)
        }
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = PacketmanUI.label(
            item.title,
            font: .systemFont(ofSize: NSFont.systemFontSize, weight: item.selection == nil ? .semibold : .regular),
            color: item.selection == nil ? .secondaryLabelColor : .labelColor
        )
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.subviews.forEach { $0.removeFromSuperview() }
        if item.selection == nil {
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            cell.addSubview(imageView)
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else {
            return
        }

        let row = tableView.selectedRow
        guard viewModel.rows.indices.contains(row),
              let selection = viewModel.rows[row].selection else {
            return
        }

        delegate?.sidebarViewController(self, didSelect: selection)
    }
}
