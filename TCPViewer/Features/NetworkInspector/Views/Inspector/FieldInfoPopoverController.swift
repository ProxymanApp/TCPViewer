import AppKit

enum FieldExplanations {
    // Curated starter set: keys are PacketDetailNode.id values produced by PcapPlusPlusCore.
    // Match by exact id first; fall back to suffix match (for namespaced ids like "tcp.flags.ack").
    private static let entries: [String: String] = [
        // TCP
        "tcp.src_port": "TCP source port — the ephemeral port the sender chose for this connection.",
        "tcp.dst_port": "TCP destination port — well-known ports identify common services (e.g. 443 = HTTPS).",
        "tcp.seq": "TCP sequence number — the byte offset of the first payload byte in this segment within the stream.",
        "tcp.ack": "TCP acknowledgment number — the next byte the sender expects to receive from the peer.",
        "tcp.window": "Advertised receive window: how many more bytes the sender is willing to buffer.",
        "tcp.flags": "TCP control flags. Common combinations: SYN (open), SYN+ACK (open reply), ACK (data/keepalive), FIN (close), RST (abort), PSH (push to app).",
        "tcp.flags.syn": "SYN — initiates a connection (handshake step 1).",
        "tcp.flags.ack": "ACK — acknowledges previously received bytes.",
        "tcp.flags.fin": "FIN — sender has no more data; graceful close.",
        "tcp.flags.rst": "RST — abort the connection immediately.",
        "tcp.flags.psh": "PSH — deliver buffered data to the application without waiting.",
        "tcp.checksum": "TCP checksum — covers header + payload + pseudo-header. Validity tells you whether the segment was corrupted in transit.",

        // IPv4
        "ipv4.ttl": "Time To Live — decremented at each hop. Reaches zero → packet dropped (used by traceroute).",
        "ipv4.protocol": "IP protocol number identifying the next-layer protocol (6 = TCP, 17 = UDP, 1 = ICMP).",
        "ipv4.src": "IPv4 source address.",
        "ipv4.dst": "IPv4 destination address.",
        "ipv4.checksum": "IPv4 header checksum — header-only, recomputed at each hop because TTL changes.",

        // Ethernet
        "ethernet.type": "EtherType — identifies the next protocol (0x0800 = IPv4, 0x86DD = IPv6, 0x0806 = ARP).",

        // TLS
        "tls.record.version": "TLS record-layer version (1.2 = 0x0303, 1.3 = 0x0304). The handshake may negotiate a different version.",
        "tls.record.type": "Record content type: 22 = Handshake, 23 = Application Data, 21 = Alert, 20 = ChangeCipherSpec.",
        "tls.record.length": "Length of this TLS record's encrypted payload (not the full TCP segment).",
    ]

    static func explanation(for nodeID: String) -> String? {
        if let direct = entries[nodeID] {
            return direct
        }
        // Suffix match on common short names (e.g. node id "ipv4.0.ttl" → "ipv4.ttl").
        for (key, value) in entries {
            if nodeID.hasSuffix(key) {
                return value
            }
        }
        return nil
    }

    static func hasExplanation(for nodeID: String) -> Bool {
        explanation(for: nodeID) != nil
    }
}

final class FieldInfoPopoverController: NSViewController {
    private let textView: NSTextField

    init(text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        self.textView = label
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            textView.widthAnchor.constraint(equalToConstant: 280),
        ])
        view = container
    }

    static func present(text: String, relativeTo view: NSView) {
        let controller = FieldInfoPopoverController(text: text)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
}
