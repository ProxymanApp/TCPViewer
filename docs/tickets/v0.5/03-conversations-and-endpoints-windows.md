# v0.5.3 Conversations And Endpoints Windows

## Summary
Define aggregated TCP/UDP conversation and endpoint views so analysts can move from packet-level browsing to flow-level understanding.

## What To Build
- Model conversations and endpoints with counts, bytes, duration, bitrate, and filter handoff.
- Define sorting, filtering, and navigation from summary rows back to packet views.
- Cover how display filters affect totals and percentages.

## Requirements
- Conversations and endpoints must reflect the active trace and filter state consistently.
- Aggregates must be stable enough for later graph handoff and export.
- The design must handle both live and offline traces.

## Dependencies
- v0.2.5 packet ingest model.
- v0.4.1 display filter engine v1.

## Tests
- Unit tests: cover aggregation, duration/bitrate calculations, and filter handoff generation.
- Integration tests: cover conversations and endpoints on mixed traffic, filtered subsets, and live-update-style traces.
- UI tests: out of scope.

## Out Of Scope
- Protocol hierarchy.
- Transport anomaly diagnostics.
