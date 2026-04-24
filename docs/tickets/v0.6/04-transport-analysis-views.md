# v0.6.4 Transport Analysis Views

## Summary
Define flow-graph and TCP stream analysis views that help analysts understand timing, sequence behavior, and packet direction over time.

## What To Build
- Specify the data models for flow graph and TCP timing/sequence views.
- Define packet-selection and filter handoff between these views and the main packet list.
- Establish the minimum graph set required before later I/O graph work.

## Requirements
- Graphs must stay grounded in packet-level truth and allow drill-back into packets.
- The views must support incomplete traces without pretending they are complete.
- Calculations must be deterministic across repeated loads of the same trace.

## Dependencies
- v0.6.1 TCP reassembly and IP defragmentation.
- v0.5.3 conversations and endpoints windows.

## Tests
- Unit tests: cover graph-point generation, sequence/timing calculations, and packet-row mapping.
- Integration tests: cover flow-graph and timing views on normal, retransmitted, and incomplete TCP fixtures.
- UI tests: out of scope.

## Out Of Scope
- I/O graphs across the full trace timeline.
- Latency tooling for higher-level protocols.
