import AppKit

protocol InspectorTabBarDelegate: AnyObject {
    func inspectorTabBar(_ bar: InspectorTabBar, didSelect tab: PacketInspectorTab)
}

final class InspectorTabBar: NSView {
    weak var delegate: InspectorTabBarDelegate?

    private let segmented = NSSegmentedControl(
        labels: PacketInspectorTab.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    init() {
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ tab: PacketInspectorTab) {
        if let index = PacketInspectorTab.allCases.firstIndex(of: tab) {
            segmented.selectedSegment = index
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = InspectorTheme.Palette.headerBackground.cgColor

        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.segmentStyle = .rounded
        segmented.target = self
        segmented.action = #selector(segmentChanged(_:))
        addSubview(segmented)

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor, constant: InspectorTheme.Spacing.headerHorizontal),
            segmented.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -InspectorTheme.Spacing.headerHorizontal),
            segmented.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            segmented.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
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

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard PacketInspectorTab.allCases.indices.contains(index) else {
            return
        }

        delegate?.inspectorTabBar(self, didSelect: PacketInspectorTab.allCases[index])
    }
}
