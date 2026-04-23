# v0.2.5 Packet Ingest Model

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
