//
//  PacketTableCells.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/4/26.
//

import AppKit

final class PacketTextCell: NSTextFieldCell {
    private static let leftPadding: CGFloat = 5
    private static let rightPadding: CGFloat = 4

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
        var drawingRect = super.drawingRect(forBounds: rect)
        drawingRect.origin.x += Self.leftPadding
        drawingRect.size.width = max(0, drawingRect.width - Self.leftPadding - Self.rightPadding)
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

    override func copy(with zone: NSZone? = nil) -> Any {
        let savedProtocolText = protocolText
        let savedSeverity = severity
        protocolText = ""
        defer {
            protocolText = savedProtocolText
            severity = savedSeverity
        }

        let copied = super.copy(with: zone) as! PacketProtocolCell
        // NSCell copies bitwise; refill Swift strings so copied cells own valid storage.
        copied.protocolText = String(decoding: savedProtocolText.utf8, as: UTF8.self)
        copied.severity = savedSeverity
        return copied
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
        PacketProtocolPalette.fill(for: protocolText, severity: severity)
    }

    private func textColor(for protocolText: String, severity: PacketSeverity) -> NSColor {
        PacketProtocolPalette.tint(for: protocolText, severity: severity)
    }
}

enum PacketProtocolPalette {
    static func tint(for protocolText: String, severity: PacketSeverity = .normal) -> NSColor {
        switch protocolText.uppercased() {
        case "TCP":
            return .systemOrange
        case "UDP":
            return .systemCyan
        case "TLS", "SSL", "HTTPS", "TLSV1", "TLSV1.1", "TLSV1.2", "TLSV1.3":
            return .systemGreen
        case "HTTP":
            return .systemPink
        case "DNS":
            return .systemPurple
        case "ICMP", "ICMPV6":
            return .systemRed
        case "ARP":
            return .systemTeal
        case "IPV4", "IPV6", "IP":
            return .systemBlue
        case "ETHERNET", "ETH":
            return .systemGray
        default:
            if severity != .normal {
                return .systemOrange
            }

            return .controlAccentColor
        }
    }

    static func fill(for protocolText: String, severity: PacketSeverity = .normal) -> NSColor {
        switch protocolText.uppercased() {
        case "TCP":
            return .systemOrange.withAlphaComponent(0.16)
        case "UDP":
            return .systemCyan.withAlphaComponent(0.18)
        case "TLS", "SSL", "HTTPS", "TLSV1", "TLSV1.1", "TLSV1.2", "TLSV1.3":
            return .systemGreen.withAlphaComponent(0.16)
        case "HTTP":
            return .systemPink.withAlphaComponent(0.16)
        case "DNS":
            return .systemPurple.withAlphaComponent(0.16)
        case "ICMP", "ICMPV6":
            return .systemRed.withAlphaComponent(0.14)
        case "ARP":
            return .systemTeal.withAlphaComponent(0.16)
        case "IPV4", "IPV6", "IP":
            return .systemBlue.withAlphaComponent(0.14)
        case "ETHERNET", "ETH":
            return .systemGray.withAlphaComponent(0.18)
        default:
            if severity != .normal {
                return .systemOrange.withAlphaComponent(0.18)
            }

            return .controlAccentColor.withAlphaComponent(0.14)
        }
    }
}

final class PacketClientCell: NSTextFieldCell {
    private static let iconCache = PacketClientIconCache()
    private static let horizontalPadding: CGFloat = 6
    private static let iconSize: CGFloat = 16
    private static let iconTextSpacing: CGFloat = 4
    private var iconFilePath: String?

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
    func configure(displayName: String, iconFilePath: String?, configuration: AppConfiguration) {
        self.iconFilePath = PacketClientIconCache.normalizedIconPath(iconFilePath)
        stringValue = displayName
        font = configuration.packetFont(weight: .regular)
        textColor = .secondaryLabelColor
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let savedIconFilePath = iconFilePath
        iconFilePath = nil
        defer {
            iconFilePath = savedIconFilePath
        }

        let copied = super.copy(with: zone) as! PacketClientCell
        // NSCell copies bitwise; refill Swift strings so copied cells own valid storage.
        copied.iconFilePath = savedIconFilePath.map { String(decoding: $0.utf8, as: UTF8.self) }
        return copied
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
        guard let icon = Self.iconCache.image(forPath: iconFilePath) else {
            let textFrame = cellFrame.insetBy(dx: Self.horizontalPadding, dy: 0)
            super.drawInterior(withFrame: textFrame, in: controlView)
            return
        }

        let iconFrame = NSRect(
            x: cellFrame.minX + Self.horizontalPadding,
            y: cellFrame.midY - Self.iconSize / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        icon.draw(in: iconFrame)

        let textX = iconFrame.maxX + Self.iconTextSpacing
        let textFrame = NSRect(
            x: textX,
            y: cellFrame.minY,
            width: max(0, cellFrame.maxX - textX - Self.horizontalPadding),
            height: cellFrame.height
        )
        super.drawInterior(withFrame: textFrame, in: controlView)
    }
}
