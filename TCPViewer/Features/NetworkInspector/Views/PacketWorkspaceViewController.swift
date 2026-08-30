//
//  PacketWorkspaceViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import AppKit
import PcapPlusPlusCore

protocol PacketWorkspaceViewControllerDelegate: AnyObject {
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didSelectPacket identifier: PacketSummary.ID?)
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestPinPackets identifiers: [PacketSummary.ID]
    )
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestSavePackets identifiers: [PacketSummary.ID])
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestFollowTCPStream packetID: PacketSummary.ID)
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestSetComment comment: String,
        onPackets identifiers: [PacketSummary.ID]
    )
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestApplyTextStyle mutation: PacketTextStyleMutation,
        toPackets identifiers: [PacketSummary.ID]
    )
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestExportPackets identifiers: [PacketSummary.ID], format: CaptureFileFormat)
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestDeletePackets identifiers: [PacketSummary.ID])
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        inspectPacket identifier: PacketSummary.ID,
        completion: @escaping TCPViewerCompletion<PacketInspection>
    )
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didUpdateStructuredFilterGroup group: PacketStructuredFilterGroup)
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestSaveCustomFilterNamed name: String, group: PacketStructuredFilterGroup)
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestOverrideCustomFilter filterID: PacketCustomFilter.ID,
        group: PacketStructuredFilterGroup
    )
    func packetWorkspaceViewControllerDidRequestResetQuickFilters(_ controller: PacketWorkspaceViewController)
    func packetWorkspaceViewControllerCanAddStructuredFilter(_ controller: PacketWorkspaceViewController) -> Bool
    func packetWorkspaceViewControllerCanSaveCustomFilter(_ controller: PacketWorkspaceViewController) -> Bool
    func packetWorkspaceViewControllerDidRequestStructuredFilterPaywall(_ controller: PacketWorkspaceViewController)
    func packetWorkspaceViewControllerDidRequestHideStructuredFilter(_ controller: PacketWorkspaceViewController)
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didUpdateWiresharkFilterExpression expression: String
    )
    func packetWorkspaceViewControllerDidRequestApplyWiresharkFilter(_ controller: PacketWorkspaceViewController)
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestApplyWiresharkFilterBeforeSaving completion: @escaping (Bool) -> Void
    )
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestSaveWiresharkFilterNamed name: String
    )
    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestOverrideWiresharkFilter filterID: PacketCustomFilter.ID
    )
}

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        drawingRect.origin.y += floor((drawingRect.height - textHeight) / 2)
        drawingRect.size.height = textHeight
        return drawingRect
    }
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
    private(set) var showsResetFiltersButton = false
    private(set) var activeFilterLabels: [String] = []

    // Convert the root snapshot into packet-workspace-only render data.
    func render(snapshot: NetworkInspectorSnapshot) {
        countText = "\(snapshot.visiblePacketCount) visible"
        totalText = snapshot.visiblePacketCount == snapshot.totalPacketCount ? nil : "of \(snapshot.totalPacketCount)"
        chips = snapshot.displayFilterChips
        isEmpty = snapshot.packetRows.isEmpty
        showsResetFiltersButton = isEmpty && snapshot.isQuickFilterActive
        activeFilterLabels = isEmpty ? snapshot.activeFilterBarLabels : []

        if snapshot.isPacketTableFiltering && isEmpty {
            showsResetFiltersButton = false
            activeFilterLabels = []
        }

        if !activeFilterLabels.isEmpty {
            emptyTitle = "No Matching Packets"
            emptyMessage = "Filtered by selected filters"
            emptyImageName = "line.3.horizontal.decrease.circle"
            return
        }

        switch snapshot.selectedSourceListSelection {
        case .pinned:
            emptyTitle = "Pinned Packets"
            emptyMessage = "Pinned matches will appear here as packets arrive."
            emptyImageName = "pin.fill"
        case .pinnedItem, .pinnedItemDomain, .pinnedItemIPAddress:
            emptyTitle = "Pinned Packets"
            emptyMessage = "No packets match this pinned item yet."
            emptyImageName = "pin.fill"
        case .saved:
            emptyTitle = "Saved Packets"
            emptyMessage = "Saved packets appear here after using the packet table menu."
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
    private let structuredFilterController = PacketStructuredFilterViewController()
    private let wiresharkFilterController = PacketWiresharkFilterViewController()
    private let tableController: PacketTableViewController
    private var placeholderView: NSView?
    private var isStructuredFilterVisible = false
    private var filterMode: PacketFilterMode = .builder
    private var contentTopToBuilderBottomConstraint: NSLayoutConstraint?
    private var contentTopToWiresharkBottomConstraint: NSLayoutConstraint?
    private var contentTopToSafeAreaConstraint: NSLayoutConstraint?

    init(configuration: AppConfiguration) {
        self.tableController = PacketTableViewController(configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = TCPViewerDynamicBackgroundView(backgroundColor: .controlBackgroundColor)
        setupContent()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableController.delegate = self
        structuredFilterController.delegate = self
        wiresharkFilterController.delegate = self
    }

    // Render the packet workspace and swap between the table and empty state as needed.
    func render(snapshot: NetworkInspectorSnapshot) {
        viewModel.render(snapshot: snapshot)
        structuredFilterController.render(
            group: snapshot.structuredFilterGroup,
            isFiltering: snapshot.isPacketTableFiltering,
            customFilterItems: snapshot.customFilterItems
        )
        wiresharkFilterController.render(
            state: snapshot.wiresharkFilterState,
            customFilterItems: snapshot.customFilterItems
        )
        applyFilterVisibility(snapshot.isStructuredFilterVisible, mode: snapshot.filterMode)

        if viewModel.isEmpty {
            showPlaceholder(
                title: viewModel.emptyTitle,
                message: viewModel.emptyMessage,
                imageName: viewModel.emptyImageName,
                showsResetFiltersButton: viewModel.showsResetFiltersButton,
                activeFilterLabels: viewModel.activeFilterLabels
            )
        } else {
            showTable()
            tableController.render(snapshot: snapshot)
        }
    }

    // Forward packet navigation to the table that owns the visible row ordering.
    @discardableResult
    func scrollPacketToVisible(_ identifier: PacketSummary.ID) -> Bool {
        guard !viewModel.isEmpty else {
            return false
        }

        showTable()
        return tableController.scrollPacketToVisible(identifier)
    }

    func focusStructuredFilter() {
        applyFilterVisibility(true, mode: filterMode)
        switch filterMode {
        case .builder:
            structuredFilterController.focusLastFilterTextField()
        case .wireshark:
            wiresharkFilterController.focusExpressionField()
        }
    }

    func createCustomColumn(from request: PacketCustomColumnRequest) {
        tableController.createCustomColumn(from: request)
    }

    private func setupContent() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        addChild(structuredFilterController)
        addChild(wiresharkFilterController)
        addChild(tableController)
        structuredFilterController.view.translatesAutoresizingMaskIntoConstraints = false
        wiresharkFilterController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(structuredFilterController.view)
        view.addSubview(wiresharkFilterController.view)

        let contentTopToBuilderBottomConstraint = contentContainer.topAnchor.constraint(equalTo: structuredFilterController.view.bottomAnchor)
        let contentTopToWiresharkBottomConstraint = contentContainer.topAnchor.constraint(equalTo: wiresharkFilterController.view.bottomAnchor)
        let contentTopToSafeAreaConstraint = contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        self.contentTopToBuilderBottomConstraint = contentTopToBuilderBottomConstraint
        self.contentTopToWiresharkBottomConstraint = contentTopToWiresharkBottomConstraint
        self.contentTopToSafeAreaConstraint = contentTopToSafeAreaConstraint
        structuredFilterController.view.isHidden = true
        wiresharkFilterController.view.isHidden = true

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentTopToSafeAreaConstraint,
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            structuredFilterController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            structuredFilterController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            structuredFilterController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            wiresharkFilterController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wiresharkFilterController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wiresharkFilterController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    private func applyFilterVisibility(_ isVisible: Bool, mode: PacketFilterMode) {
        guard isStructuredFilterVisible != isVisible || filterMode != mode else {
            return
        }

        isStructuredFilterVisible = isVisible
        filterMode = mode
        structuredFilterController.view.isHidden = !isVisible || mode != .builder
        wiresharkFilterController.view.isHidden = !isVisible || mode != .wireshark
        contentTopToBuilderBottomConstraint?.isActive = false
        contentTopToWiresharkBottomConstraint?.isActive = false
        if isVisible {
            contentTopToSafeAreaConstraint?.isActive = false
            switch mode {
            case .builder:
                contentTopToBuilderBottomConstraint?.isActive = true
            case .wireshark:
                contentTopToWiresharkBottomConstraint?.isActive = true
            }
        } else {
            contentTopToSafeAreaConstraint?.isActive = true
        }
    }

    private func showPlaceholder(
        title: String,
        message: String,
        imageName: String,
        showsResetFiltersButton: Bool,
        activeFilterLabels: [String]
    ) {
        if tableController.view.superview != nil {
            tableController.view.removeFromSuperview()
        }

        placeholderView?.removeFromSuperview()
        let placeholder = makePlaceholder(
            title: title,
            imageName: imageName,
            message: message,
            showsResetFiltersButton: showsResetFiltersButton,
            activeFilterLabels: activeFilterLabels
        )
        TCPViewerUI.pin(placeholder, to: contentContainer)
        placeholderView = placeholder
    }

    private func makePlaceholder(
        title: String,
        imageName: String,
        message: String,
        showsResetFiltersButton: Bool,
        activeFilterLabels: [String]
    ) -> NSView {
        let imageView = NSImageView(image: TCPViewerUI.image(imageName) ?? NSImage())
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor

        let titleLabel = TCPViewerUI.label(title, font: .systemFont(ofSize: 19, weight: .semibold))
        titleLabel.alignment = .center

        let messageView: NSView
        let messageWidthConstraint: NSLayoutConstraint?
        if activeFilterLabels.isEmpty {
            let messageLabel = TCPViewerUI.label(message, font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)
            messageLabel.alignment = .center
            messageLabel.maximumNumberOfLines = 3
            messageView = messageLabel
            messageWidthConstraint = messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        } else {
            messageView = makeFilterMessage(labels: activeFilterLabels)
            messageWidthConstraint = nil
        }

        var arrangedViews: [NSView] = [imageView, titleLabel, messageView]
        if showsResetFiltersButton {
            let resetButton = NSButton(title: "Reset Filters", target: self, action: #selector(resetQuickFilters(_:)))
            resetButton.bezelStyle = .rounded
            resetButton.controlSize = .regular
            resetButton.image = TCPViewerUI.image("arrow.counterclockwise")
            resetButton.imagePosition = .imageLeading
            arrangedViews.append(resetButton)
        }

        let stack = NSStackView(views: arrangedViews)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: imageView)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        messageWidthConstraint?.isActive = true
        return container
    }

    private func makeFilterMessage(labels: [String]) -> NSView {
        let prefixLabel = TCPViewerUI.label(
            "Filtered by",
            font: .systemFont(ofSize: NSFont.systemFontSize),
            color: .secondaryLabelColor
        )

        let visibleLabels = Array(labels.prefix(4))
        var views: [NSView] = [prefixLabel] + visibleLabels.map(makeFilterChip(title:))
        if labels.count > visibleLabels.count {
            views.append(makeFilterChip(title: "+\(labels.count - visibleLabels.count)"))
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func makeFilterChip(title: String) -> NSView {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let label = TCPViewerUI.label(title, font: font)
        label.cell = VerticallyCenteredTextFieldCell(textCell: title)
        label.font = font
        label.textColor = .labelColor
        label.alignment = .center
        label.cell?.lineBreakMode = .byTruncatingTail

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 5
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.separatorColor.cgColor
        chip.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65).cgColor

        TCPViewerUI.pin(label, to: chip, insets: NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9))
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 24),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 130),
        ])
        return chip
    }

    private func showTable() {
        placeholderView?.removeFromSuperview()
        placeholderView = nil

        if tableController.view.superview == nil {
            TCPViewerUI.pin(tableController.view, to: contentContainer)
        }
    }

    @objc private func resetQuickFilters(_ sender: Any?) {
        delegate?.packetWorkspaceViewControllerDidRequestResetQuickFilters(self)
    }
}

#if DEBUG
extension PacketWorkspaceViewController {
    // Selects a random packet row through the table controller for debug crash reproduction.
    @discardableResult
    func selectRandomPacketRowForTesting() -> Bool {
        guard !viewModel.isEmpty else {
            return false
        }

        showTable()
        return tableController.selectRandomPacketRowForTesting()
    }
}
#endif

extension PacketWorkspaceViewController: PacketTableViewControllerDelegate {
    func packetTableViewController(_ controller: PacketTableViewController, didSelectPacket identifier: PacketSummary.ID?) {
        delegate?.packetWorkspaceViewController(self, didSelectPacket: identifier)
    }

    func packetTableViewController(
        _ controller: PacketTableViewController,
        didRequestPinPackets identifiers: [PacketSummary.ID]
    ) {
        delegate?.packetWorkspaceViewController(
            self,
            didRequestPinPackets: identifiers
        )
    }

    func packetTableViewController(_ controller: PacketTableViewController, didRequestSavePackets identifiers: [PacketSummary.ID]) {
        delegate?.packetWorkspaceViewController(self, didRequestSavePackets: identifiers)
    }

    func packetTableViewController(_ controller: PacketTableViewController, didRequestFollowTCPStream packetID: PacketSummary.ID) {
        delegate?.packetWorkspaceViewController(self, didRequestFollowTCPStream: packetID)
    }

    func packetTableViewController(
        _ controller: PacketTableViewController,
        didRequestSetComment comment: String,
        onPackets identifiers: [PacketSummary.ID]
    ) {
        delegate?.packetWorkspaceViewController(
            self,
            didRequestSetComment: comment,
            onPackets: identifiers
        )
    }

    func packetTableViewController(
        _ controller: PacketTableViewController,
        didRequestApplyTextStyle mutation: PacketTextStyleMutation,
        toPackets identifiers: [PacketSummary.ID]
    ) {
        delegate?.packetWorkspaceViewController(
            self,
            didRequestApplyTextStyle: mutation,
            toPackets: identifiers
        )
    }

    func packetTableViewController(_ controller: PacketTableViewController, didRequestExportPackets identifiers: [PacketSummary.ID], format: CaptureFileFormat) {
        delegate?.packetWorkspaceViewController(self, didRequestExportPackets: identifiers, format: format)
    }

    func packetTableViewController(_ controller: PacketTableViewController, didRequestDeletePackets identifiers: [PacketSummary.ID]) {
        delegate?.packetWorkspaceViewController(self, didRequestDeletePackets: identifiers)
    }

    func packetTableViewController(
        _ controller: PacketTableViewController,
        inspectPacket identifier: PacketSummary.ID,
        completion: @escaping TCPViewerCompletion<PacketInspection>
    ) {
        delegate?.packetWorkspaceViewController(self, inspectPacket: identifier, completion: completion)
    }
}

extension PacketWorkspaceViewController: PacketStructuredFilterViewControllerDelegate {
    func packetStructuredFilterViewController(_ controller: PacketStructuredFilterViewController, didUpdate group: PacketStructuredFilterGroup) {
        delegate?.packetWorkspaceViewController(self, didUpdateStructuredFilterGroup: group)
    }

    func packetStructuredFilterViewController(
        _ controller: PacketStructuredFilterViewController,
        didRequestSaveCustomFilterNamed name: String,
        group: PacketStructuredFilterGroup
    ) {
        delegate?.packetWorkspaceViewController(self, didRequestSaveCustomFilterNamed: name, group: group)
    }

    func packetStructuredFilterViewController(
        _ controller: PacketStructuredFilterViewController,
        didRequestOverrideCustomFilter filterID: PacketCustomFilter.ID,
        group: PacketStructuredFilterGroup
    ) {
        delegate?.packetWorkspaceViewController(self, didRequestOverrideCustomFilter: filterID, group: group)
    }

    func packetStructuredFilterViewControllerCanAddFilter(_ controller: PacketStructuredFilterViewController) -> Bool {
        delegate?.packetWorkspaceViewControllerCanAddStructuredFilter(self) ?? true
    }

    func packetStructuredFilterViewControllerCanSaveCustomFilter(_ controller: PacketStructuredFilterViewController) -> Bool {
        delegate?.packetWorkspaceViewControllerCanSaveCustomFilter(self) ?? true
    }

    func packetStructuredFilterViewControllerDidRequestPaywall(_ controller: PacketStructuredFilterViewController) {
        delegate?.packetWorkspaceViewControllerDidRequestStructuredFilterPaywall(self)
    }

    func packetStructuredFilterViewControllerDidRequestHide(_ controller: PacketStructuredFilterViewController) {
        delegate?.packetWorkspaceViewControllerDidRequestHideStructuredFilter(self)
    }
}

extension PacketWorkspaceViewController: PacketWiresharkFilterViewControllerDelegate {
    func packetWiresharkFilterViewController(
        _ controller: PacketWiresharkFilterViewController,
        didUpdateExpression expression: String
    ) {
        delegate?.packetWorkspaceViewController(self, didUpdateWiresharkFilterExpression: expression)
    }

    func packetWiresharkFilterViewControllerDidRequestApply(_ controller: PacketWiresharkFilterViewController) {
        delegate?.packetWorkspaceViewControllerDidRequestApplyWiresharkFilter(self)
    }

    func packetWiresharkFilterViewController(
        _ controller: PacketWiresharkFilterViewController,
        didRequestApplyBeforeSaving completion: @escaping (Bool) -> Void
    ) {
        delegate?.packetWorkspaceViewController(
            self,
            didRequestApplyWiresharkFilterBeforeSaving: completion
        )
    }

    func packetWiresharkFilterViewController(
        _ controller: PacketWiresharkFilterViewController,
        didRequestSaveNamed name: String
    ) {
        delegate?.packetWorkspaceViewController(self, didRequestSaveWiresharkFilterNamed: name)
    }

    func packetWiresharkFilterViewController(
        _ controller: PacketWiresharkFilterViewController,
        didRequestOverrideCustomFilter filterID: PacketCustomFilter.ID
    ) {
        delegate?.packetWorkspaceViewController(self, didRequestOverrideWiresharkFilter: filterID)
    }

    func packetWiresharkFilterViewControllerCanSave(_ controller: PacketWiresharkFilterViewController) -> Bool {
        delegate?.packetWorkspaceViewControllerCanSaveCustomFilter(self) ?? true
    }

    func packetWiresharkFilterViewControllerDidRequestPaywall(_ controller: PacketWiresharkFilterViewController) {
        delegate?.packetWorkspaceViewControllerDidRequestStructuredFilterPaywall(self)
    }

    func packetWiresharkFilterViewControllerDidRequestHide(_ controller: PacketWiresharkFilterViewController) {
        delegate?.packetWorkspaceViewControllerDidRequestHideStructuredFilter(self)
    }
}
