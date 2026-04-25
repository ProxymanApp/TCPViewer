# v0.6.1 TCP Reassembly And IP Defragmentation

## Summary
Define how TCPViewer reconstructs higher-value transport and IP views so analysts can inspect complete conversations instead of fragmented packets only.

## What To Build
- Specify TCP reassembly and IP defragmentation outputs from `PcapPlusPlusCore`.
- Define how reassembled data appears in packet detail, bytes, and follow-stream workflows.
- Cover incomplete, overlapping, missing, and malformed reassembly cases.

## Requirements
- Reassembly results must be explicit about gaps and uncertainty.
- The app must keep raw packet truth available alongside reconstructed views.
- Reassembly must integrate with later HTTP, TLS, and object-export features.

## Dependencies
- v0.5.2 follow stream workflows.
- v0.2.5 packet ingest model.

## Tests
- Unit tests: cover reassembly status mapping, gap handling, and defragmented payload representation.
- Integration tests: cover in-order, out-of-order, retransmitted, missing-segment, and fragmented-packet fixtures.
- UI tests: out of scope.

## Out Of Scope
- Expert diagnostics ranking.
- Application-layer object export.
