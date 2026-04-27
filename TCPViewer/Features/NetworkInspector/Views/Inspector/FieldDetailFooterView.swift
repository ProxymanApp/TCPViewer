import AppKit
import PcapPlusPlusCore

protocol FieldDetailFooterViewDelegate: AnyObject {
    func fieldDetailFooterDidRequestRevealInRaw(_ view: FieldDetailFooterView)
}

final class FieldDetailFooterView: NSView {
    weak var delegate: FieldDetailFooterViewDelegate?

    private let summaryLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "Reveal in Raw", target: nil, action: nil)
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
        summaryLabel.font = InspectorTheme.subtitleFont(configuration)
    }

    func render(node: PacketDetailNode?, rawBytes: Data?) {
        guard let node, let range = node.byteRange, let data = rawBytes, range.length > 0 else {
            summaryLabel.stringValue = "Select a field to inspect its bytes."
            summaryLabel.textColor = .tertiaryLabelColor
            revealButton.isEnabled = false
            isHidden = node == nil
            return
        }

        isHidden = false
        let safeStart = max(0, min(range.offset, data.count))
        let safeEnd = max(safeStart, min(range.offset + range.length, data.count))
        let slice = data.subdata(in: safeStart..<safeEnd)
        let hex = slice.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
        let suffix = slice.count > 8 ? " …" : ""

        summaryLabel.stringValue = "Bytes \(safeStart)–\(safeEnd - 1)  ·  \(slice.count) B  ·  0x \(hex)\(suffix)"
        summaryLabel.textColor = .secondaryLabelColor
        revealButton.isEnabled = true
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = InspectorTheme.Palette.headerBackground.cgColor

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = InspectorTheme.subtitleFont(configuration)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.isSelectable = true

        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(revealTapped(_:))

        addSubview(summaryLabel)
        addSubview(revealButton)

        let topBorder = NSView()
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = InspectorTheme.Palette.cardBorder.cgColor
        addSubview(topBorder)

        NSLayoutConstraint.activate([
            topBorder.heightAnchor.constraint(equalToConstant: 1),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.topAnchor.constraint(equalTo: topAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: InspectorTheme.Spacing.headerHorizontal),
            summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            revealButton.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: 8),
            revealButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -InspectorTheme.Spacing.headerHorizontal),
            revealButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @objc private func revealTapped(_ sender: NSButton) {
        delegate?.fieldDetailFooterDidRequestRevealInRaw(self)
    }
}
