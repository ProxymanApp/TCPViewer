# v0.6.2 Expert Diagnostics Engine

## Summary
Define the anomaly and expert-information engine that flags retransmissions, duplicate ACKs, resets, malformed packets, checksum caveats, missing segments, and suspicious timing.

## What To Build
- Model expert events, severity, category, and packet/stream associations.
- Define the first set of transport-focused anomaly rules.
- Specify how expert events feed packet list styling, filters, and summary views.

## Requirements
- Diagnostic rules must be explainable and testable.
- False certainty must be avoided when captures are incomplete or checksums are offloaded.
- The model must scale from packet-level warnings to stream-level summaries.

## Dependencies
- v0.6.1 TCP reassembly and IP defragmentation.
- v0.2.5 packet ingest model.

## Tests
- Unit tests: cover expert-rule evaluation and severity assignment.
- Integration tests: cover retransmission, duplicate-ACK, reset, malformed, checksum, and timing fixtures.
- UI tests: out of scope.

## Out Of Scope
- Machine-learning anomaly detection.
- Security verdicting beyond transport/protocol diagnostics.
