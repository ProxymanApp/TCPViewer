import AppKit
import PcapPlusPlusCore

final class PacketTextCell: NSTextFieldCell {
    enum Style {
        case primary
        case secondary
        case warning
    }

    override init(textCell string: String) {
        super.init(textCell: string)
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        truncatesLastVisibleLine = true
    }

    convenience init() {
        self.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(style: Style, configuration: AppConfiguration) {
        font = configuration.packetFont(weight: .regular)

        switch style {
        case .primary:
            textColor = .labelColor
        case .secondary:
            textColor = .secondaryLabelColor
        case .warning:
            textColor = .systemOrange
        }
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(forBounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(forBounds: rect)
    }

    private func verticallyCenteredRect(forBounds rect: NSRect) -> NSRect {
        // Center text in compact rows so AppKit's default baseline does not sit high.
        var drawingRect = super.drawingRect(forBounds: rect).insetBy(dx: 6, dy: 0)
        let textHeight = cellSize(forBounds: drawingRect).height
        drawingRect.origin.y += floor((drawingRect.height - textHeight) / 2)
        drawingRect.size.height = textHeight
        return drawingRect
    }
}

final class PacketProtocolCell: NSTextFieldCell {
    private var protocolText = ""
    private var severity: PacketSeverity = .normal

    override init(textCell string: String) {
        super.init(textCell: string)
        alignment = .center
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        truncatesLastVisibleLine = true
    }

    convenience init() {
        self.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(protocolText: String, severity: PacketSeverity, configuration: AppConfiguration) {
        self.protocolText = protocolText
        self.severity = severity
        stringValue = protocolText
        font = configuration.packetFont(weight: .semibold)
        textColor = textColor(for: protocolText, severity: severity)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Draw protocol values as compact colored pills instead of plain table text.
        let label = protocolText.isEmpty ? stringValue : protocolText
        guard !label.isEmpty else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .monospacedSystemFont(ofSize: AppConfiguration.defaultPacketFontSize, weight: .semibold),
            .foregroundColor: textColor ?? .labelColor,
        ]
        let textSize = label.size(withAttributes: attributes)
        let pillWidth = min(max(textSize.width + 16, 42), cellFrame.width - 12)
        let pillHeight = min(cellFrame.height - 4, max(18, ceil(textSize.height + 6)))
        let pillRect = NSRect(
            x: cellFrame.midX - pillWidth / 2,
            y: cellFrame.midY - pillHeight / 2,
            width: pillWidth,
            height: pillHeight
        )

        backgroundColor(for: label, severity: severity).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()

        let textRect = NSRect(
            x: pillRect.midX - textSize.width / 2,
            y: pillRect.midY - textSize.height / 2 - 0.5,
            width: textSize.width,
            height: textSize.height
        )
        label.draw(in: textRect, withAttributes: attributes)
    }

    private func backgroundColor(for protocolText: String, severity: PacketSeverity) -> NSColor {
        if severity != .normal {
            return .systemOrange.withAlphaComponent(0.18)
        }

        switch protocolText.uppercased() {
        case "TCP":
            return .systemOrange.withAlphaComponent(0.16)
        case "UDP":
            return .systemBlue.withAlphaComponent(0.16)
        case "TLS", "SSL", "HTTPS":
            return .systemGreen.withAlphaComponent(0.16)
        case "HTTP":
            return .systemPink.withAlphaComponent(0.16)
        case "DNS":
            return .systemPurple.withAlphaComponent(0.16)
        case "ICMP":
            return .systemRed.withAlphaComponent(0.14)
        case "ARP":
            return .systemTeal.withAlphaComponent(0.16)
        default:
            return .controlAccentColor.withAlphaComponent(0.14)
        }
    }

    private func textColor(for protocolText: String, severity: PacketSeverity) -> NSColor {
        if severity != .normal {
            return .systemOrange
        }

        switch protocolText.uppercased() {
        case "TCP":
            return .systemOrange
        case "UDP":
            return .systemBlue
        case "TLS", "SSL", "HTTPS":
            return .systemGreen
        case "HTTP":
            return .systemPink
        case "DNS":
            return .systemPurple
        case "ICMP":
            return .systemRed
        case "ARP":
            return .systemTeal
        default:
            return .controlAccentColor
        }
    }
}

final class PacketClientCell: NSTextFieldCell {
    private static let iconCache = PacketClientIconCache()
    private var client: PacketClient?

    override init(textCell string: String) {
        super.init(textCell: string)
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        truncatesLastVisibleLine = true
        textColor = .labelColor
    }

    convenience init() {
        self.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Configure the reused cell with the current row's client metadata.
    func configure(client: PacketClient?, configuration: AppConfiguration) {
        self.client = client
        stringValue = client?.displayName ?? "-"
        font = configuration.packetFont(weight: .regular)
        textColor = client == nil ? .secondaryLabelColor : .labelColor
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(forBounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(forBounds: rect)
    }

    private func verticallyCenteredRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: drawingRect).height
        drawingRect.origin.y += floor((drawingRect.height - textHeight) / 2)
        drawingRect.size.height = textHeight
        return drawingRect
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let icon = Self.iconCache.image(for: client) else {
            let textFrame = cellFrame.insetBy(dx: 6, dy: 0)
            super.drawInterior(withFrame: textFrame, in: controlView)
            return
        }

        let iconSize: CGFloat = 16
        let iconFrame = NSRect(
            x: cellFrame.minX + 6,
            y: cellFrame.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        icon.draw(in: iconFrame)

        let textFrame = cellFrame.insetBy(dx: 6, dy: 0).offsetBy(dx: iconSize + 4, dy: 0)
        super.drawInterior(withFrame: textFrame, in: controlView)
    }
}
