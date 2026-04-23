# v0.2.5 Packet Ingest Model

## Status
COMPLETE

## Summary
Define the normalized packet summary model that turns raw capture input into stable app-facing rows for live and offline workflows.

## What To Build
- Model timestamps, interface source, protocol hints, addresses, ports, lengths, stream identifiers, and capture metadata.
- Define how the app receives packets incrementally without owning raw C++ types.
- Specify how malformed or partially decoded packets are represented.

## Requirements
- The summary model must work for both live capture and file playback.
- Missing data and decode errors must be explicit, not silently dropped.
- The model must support later features such as filters, graphs, follow stream, and expert events.

## Delivered Artifacts
- `PcapPlusPlusCore/CoreFacadeTypes.swift` expands `PacketSummary` with stream IDs, info summaries, capture metadata, decode status, and protocol-neutral endpoint addresses.
- `PcapPlusPlusCore/NativeBridge/PacketryNativeBridge.mm` maps one normalized packet-summary pipeline for both live and offline ingest, flags truncation, computes stream IDs when possible, and keeps raw packets inside core-owned state.
- `Packetry/WorkspaceFoundation.swift` adds `PacketIngestState` so the app only stores stable summary batches plus derived counters for visible packets, truncation, and decode issues.
- `Packetry/ContentView.swift` keeps the UI intentionally thin while verifying that live and offline packet rows, summary text, and health counters surface correctly.

## Verification
- `PcapPlusPlusCoreTests.nativeCoreLoadsTcpFixtureAndMatchesGolden()`
- `PcapPlusPlusCoreTests.nativeCoreLoadsUdpPcapngFixtureAndMatchesGolden()`
- `PcapPlusPlusCoreTests.malformedFixtureSurfacesDecodeIssuesExplicitly()`
- `PacketryTests.packetIngestStateTracksTotalsTruncationAndDecodeIssues()`

## Dependencies
- v0.2.2 live capture session lifecycle.
- v0.2.4 offline file pipeline.

## Tests
- Unit tests: cover packet-summary mapping, malformed-packet representation, and field formatting rules.
- Integration tests: cover ingest from live-capture-style fixtures and offline trace files, including malformed/truncated input.
- UI tests: out of scope.

## Out Of Scope
- Packet detail tree generation.
- Reassembly and expert analysis.
