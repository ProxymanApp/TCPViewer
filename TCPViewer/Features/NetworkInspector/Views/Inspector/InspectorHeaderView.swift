import AppKit
import PcapPlusPlusCore

final class InspectorHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let endpointsLabel = NSTextField(labelWithString: "")
    private let badgesRow = NSStackView()
    private var configuration: AppConfiguration

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyConfiguration(_ configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func render(packet: PacketSummary?, inspection: PacketInspection?) {
        guard let packet else {
            titleLabel.stringValue = "No packet selected"
            titleLabel.font = InspectorTheme.titleFont(configuration)
            titleLabel.textColor = .secondaryLabelColor
            endpointsLabel.stringValue = ""
            removeAllBadges()
            return
        }

        titleLabel.font = InspectorTheme.titleFont(configuration)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = "#\(packet.packetNumber)  ·  \(NetworkInspectorFormatters.protocolLabel(for: packet))  ·  \(NetworkInspectorFormatters.byteCount(packet.capturedLength))"

        endpointsLabel.font = InspectorTheme.subtitleFont(configuration)
        endpointsLabel.textColor = .secondaryLabelColor
        let src = NetworkInspectorFormatters.endpointLabel(packet.endpoints.source)
        let dst = NetworkInspectorFormatters.endpointLabel(packet.endpoints.destination)
        endpointsLabel.stringValue = "\(src)  →  \(dst)"

        renderBadges(packet: packet, inspection: inspection)
    }

    private func renderBadges(packet: PacketSummary, inspection: PacketInspection?) {
        removeAllBadges()
        let severity = NetworkInspectorFormatters.severity(for: packet)
        switch severity {
        case .normal:
            badgesRow.addArrangedSubview(InspectorBadgeView(text: "OK", style: .valid, configuration: configuration))
        case .partial:
            badgesRow.addArrangedSubview(InspectorBadgeView(text: "Partial", style: .warn, configuration: configuration))
        case .malformed:
            badgesRow.addArrangedSubview(InspectorBadgeView(text: "Malformed", style: .malformed, configuration: configuration))
        case .unsupported:
            badgesRow.addArrangedSubview(InspectorBadgeView(text: "Unsupported", style: .warn, configuration: configuration))
        case .truncated:
            badgesRow.addArrangedSubview(InspectorBadgeView(text: "Truncated", style: .truncated, configuration: configuration))
        }

        if packet.captureMetadata.isTruncated, severity != .truncated {
            badgesRow.addArrangedSubview(InspectorBadgeView(text: "Truncated", style: .truncated, configuration: configuration))
        }

        if packet.transportHint == .tls {
            badgesRow.addArrangedSubview(InspectorBadgeView(text: "Encrypted", style: .encrypted, configuration: configuration))
        }

        if let streamID = packet.streamID {
            badgesRow.addArrangedSubview(InspectorBadgeView(text: "Stream #\(streamID)", style: .info, configuration: configuration))
        }

        if let status = inspection?.decodeStatus, status.kind != .complete, let reason = status.reason, !reason.isEmpty {
            badgesRow.addArrangedSubview(InspectorBadgeView(text: reason, style: .warn, configuration: configuration))
        }
    }

    private func removeAllBadges() {
        for view in badgesRow.arrangedSubviews {
            badgesRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = InspectorTheme.Palette.headerBackground.cgColor

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        endpointsLabel.lineBreakMode = .byTruncatingMiddle
        endpointsLabel.maximumNumberOfLines = 1
        endpointsLabel.isSelectable = true

        badgesRow.orientation = .horizontal
        badgesRow.alignment = .centerY
        badgesRow.spacing = 4
        badgesRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, endpointsLabel, badgesRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: InspectorTheme.Spacing.headerVertical),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -InspectorTheme.Spacing.headerVertical),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: InspectorTheme.Spacing.headerHorizontal),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -InspectorTheme.Spacing.headerHorizontal),
        ])

        let bottomBorder = NSView()
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = InspectorTheme.Palette.cardBorder.cgColor
        addSubview(bottomBorder)
        NSLayoutConstraint.activate([
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
