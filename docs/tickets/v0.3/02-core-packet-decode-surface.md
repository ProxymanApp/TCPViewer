# v0.3.2 Core Packet Decode Surface

## Summary
Define the first decoded-protocol surface so analysts can inspect Ethernet, ARP, IPv4, IPv6, TCP, UDP, and generic payload details.

## What To Build
- Map core protocol layers into a stable packet-detail tree model.
- Define field naming, nesting, and raw-value access for the initial decode set.
- Specify how partially decoded or malformed packets appear in the detail tree.

## Requirements
- Decoded fields must come from `PcapPlusPlusCore` through stable app-facing models.
- Field structure must support later search, filter handoff, and copy/export workflows.
- The initial decode surface must not overpromise full Wireshark-scale dissector breadth.

## Dependencies
- v0.2.5 packet ingest model.
- v0.3.1 main three-pane analysis window.

## Tests
- Unit tests: cover mapping of decoded layers into tree nodes and malformed-layer representation.
- Integration tests: cover parsing representative Ethernet, ARP, IPv4, IPv6, TCP, UDP, and generic payload fixtures.
- UI tests: out of scope.

## Out Of Scope
- DNS, HTTP, TLS, or WebSocket-specific analysis surfaces.
- Reassembly-based decoded views.
