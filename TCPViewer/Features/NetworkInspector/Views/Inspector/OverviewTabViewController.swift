import AppKit
import PcapPlusPlusCore

final class OverviewTabViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var configuration: AppConfiguration

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = InspectorTheme.Palette.panelBackground.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = InspectorTheme.Spacing.cardSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: InspectorTheme.Spacing.outerPadding,
            left: InspectorTheme.Spacing.outerPadding,
            bottom: InspectorTheme.Spacing.outerPadding,
            right: InspectorTheme.Spacing.outerPadding
        )

        let documentContainer = NSView()
        documentContainer.translatesAutoresizingMaskIntoConstraints = false
        documentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor),
        ])
        scrollView.documentView = documentContainer

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            documentContainer.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        view = container
    }

    func applyConfiguration(_ configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func render(state: PacketInspectorRenderState) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let packet = state.selectedPacket else {
            stack.addArrangedSubview(emptyCard(message: state.statusMessage))
            return
        }

        stack.addArrangedSubview(makeEndpointsCard(packet: packet))
        stack.addArrangedSubview(makeFlagsCard(packet: packet, inspection: state.inspection))
        stack.addArrangedSubview(makeTimingCard(packet: packet))
        stack.addArrangedSubview(makePayloadCard(packet: packet, inspection: state.inspection))

        // Make every card stretch to the stack width.
        for card in stack.arrangedSubviews {
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * InspectorTheme.Spacing.outerPadding).isActive = true
        }
    }

    // MARK: - Cards

    private func makeEndpointsCard(packet: PacketSummary) -> NSView {
        let title = InspectorTheme.sectionTitleLabel("Endpoints", configuration: configuration)
        let src = NetworkInspectorFormatters.endpointLabel(packet.endpoints.source)
        let dst = NetworkInspectorFormatters.endpointLabel(packet.endpoints.destination)

        let srcLabel = makeMonoLabel(text: src)
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil) ?? NSImage())
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let dstLabel = makeMonoLabel(text: dst)

        let interfaceRow: NSView? = {
            let interface = packet.captureMetadata.interfaceName ?? packet.interfaceID
            guard let interface, !interface.isEmpty else { return nil }
            return InspectorTheme.keyValueRow(label: "Interface", value: interface, configuration: configuration)
        }()

        var rows: [NSView] = [title, srcLabel, arrow, dstLabel]
        if let interfaceRow {
            rows.append(InspectorTheme.rowDivider())
            rows.append(interfaceRow)
        }
        if let client = packet.client {
            rows.append(InspectorTheme.rowDivider())
            rows.append(InspectorTheme.keyValueRow(label: "Client", value: client.displayName, configuration: configuration))
        }

        return cardStack(rows: rows, spacing: 4)
    }

    private func makeFlagsCard(packet: PacketSummary, inspection: PacketInspection?) -> NSView {
        let title = InspectorTheme.sectionTitleLabel("Decode", configuration: configuration)
        var rows: [NSView] = [title]

        if let flags = packet.tcpFlags, !flags.isEmpty {
            rows.append(InspectorTheme.keyValueRow(label: "Flags", value: flags, configuration: configuration))
        }

        let statusValue = inspection.map { NetworkInspectorFormatters.decodeStatusLabel($0.decodeStatus) } ?? NetworkInspectorFormatters.decodeStatusLabel(packet.decodeStatus)
        let statusColor: NSColor = {
            switch (inspection?.decodeStatus.kind ?? packet.decodeStatus.kind) {
            case .complete: return .systemGreen
            case .partial:  return .systemOrange
            case .malformed: return .systemRed
            case .unsupported: return .secondaryLabelColor
            @unknown default: return .secondaryLabelColor
            }
        }()
        rows.append(InspectorTheme.keyValueRow(label: "Status", value: statusValue, valueColor: statusColor, configuration: configuration))

        if let reason = inspection?.decodeStatus.reason ?? packet.decodeStatus.reason, !reason.isEmpty {
            rows.append(InspectorTheme.keyValueRow(label: "Reason", value: reason, configuration: configuration))
        }

        if rows.count == 1 {
            rows.append(InspectorTheme.keyValueRow(label: "—", value: "No decode flags", configuration: configuration))
        }

        return cardStack(rows: rows)
    }

    private func makeTimingCard(packet: PacketSummary) -> NSView {
        let title = InspectorTheme.sectionTitleLabel("Timing", configuration: configuration)
        let captured = NetworkInspectorFormatters.packetTime.string(from: packet.timestamp)
        let rows: [NSView] = [
            title,
            InspectorTheme.keyValueRow(label: "Captured", value: captured, configuration: configuration),
        ]
        return cardStack(rows: rows)
    }

    private func makePayloadCard(packet: PacketSummary, inspection: PacketInspection?) -> NSView {
        let title = InspectorTheme.sectionTitleLabel("Payload", configuration: configuration)
        var rows: [NSView] = [title]

        rows.append(InspectorTheme.keyValueRow(label: "Captured", value: NetworkInspectorFormatters.byteCount(packet.capturedLength), configuration: configuration))
        rows.append(InspectorTheme.keyValueRow(label: "On Wire", value: NetworkInspectorFormatters.byteCount(packet.originalLength), configuration: configuration))

        if let length = packet.tcpPayloadLength {
            rows.append(InspectorTheme.keyValueRow(label: "TCP Payload", value: NetworkInspectorFormatters.byteCount(length), configuration: configuration))
        }

        if !packet.infoSummary.isEmpty {
            rows.append(InspectorTheme.keyValueRow(label: "Info", value: packet.infoSummary, configuration: configuration))
        }

        if let summary = inspection?.detailNodes.last(where: { $0.kind == .layer })?.value, !summary.isEmpty {
            rows.append(InspectorTheme.keyValueRow(label: "Top Layer", value: summary, configuration: configuration))
        }

        return cardStack(rows: rows)
    }

    private func emptyCard(message: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return InspectorTheme.card(content: label, padding: 24)
    }

    // MARK: - Helpers

    private func cardStack(rows: [NSView], spacing: CGFloat = InspectorTheme.Spacing.rowSpacing) -> NSView {
        let inner = NSStackView(views: rows)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = spacing
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        return InspectorTheme.card(content: inner)
    }

    private func makeMonoLabel(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = InspectorTheme.subtitleFont(configuration)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.isSelectable = true
        return label
    }
}
