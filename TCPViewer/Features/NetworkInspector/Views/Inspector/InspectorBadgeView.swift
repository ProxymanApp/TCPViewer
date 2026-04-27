import AppKit
import PcapPlusPlusCore

enum InspectorBadgeStyle {
    case valid
    case warn
    case malformed
    case encrypted
    case info
    case truncated

    var tint: NSColor {
        switch self {
        case .valid:      return .systemGreen
        case .warn:       return .systemOrange
        case .malformed:  return .systemRed
        case .encrypted:  return .systemTeal
        case .info:       return .systemBlue
        case .truncated:  return .systemYellow
        }
    }
}

final class InspectorBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, style: InspectorBadgeStyle, configuration: AppConfiguration) {
        super.init(frame: .zero)
        setup()
        configure(text: text, style: style, configuration: configuration)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, style: InspectorBadgeStyle, configuration: AppConfiguration) {
        label.stringValue = text.uppercased()
        label.font = InspectorTheme.badgeFont(configuration)
        label.textColor = style.tint.blended(withFraction: 0.35, of: .labelColor) ?? style.tint
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = InspectorTheme.Radius.badge
        layer?.backgroundColor = style.tint.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = style.tint.withAlphaComponent(0.28).cgColor
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: labelSize.width + 10, height: labelSize.height + 2)
    }
}

enum InspectorBadgeClassifier {
    struct Badge {
        let text: String
        let style: InspectorBadgeStyle
    }

    static func badges(forField node: PacketDetailNode) -> [Badge] {
        var result: [Badge] = []
        if node.kind == .warning {
            result.append(Badge(text: "Warn", style: .warn))
            return result
        }

        let id = node.id.lowercased()
        let name = node.name.lowercased()
        let value = (node.value ?? "").lowercased()

        if id.contains("checksum") || name.contains("checksum") {
            if value.contains("valid") || value.contains("correct") {
                result.append(Badge(text: "Valid", style: .valid))
            } else if value.contains("invalid") || value.contains("incorrect") || value.contains("bad") {
                result.append(Badge(text: "Bad", style: .malformed))
            }
        }

        if (id.contains("tls") || id.contains("ssl")) && (name.contains("application data") || value.contains("application data") || value.contains("encrypted")) {
            result.append(Badge(text: "Encrypted", style: .encrypted))
        }

        return result
    }
}
