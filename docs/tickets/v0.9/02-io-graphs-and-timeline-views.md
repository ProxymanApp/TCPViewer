# v0.9.2 I/O Graphs And Timeline Views

## Summary
Define timeline-based graphing for packet counts, throughput, latency-oriented views, and burst/stall troubleshooting across the whole trace.

## What To Build
- Specify I/O graph data series, interval selection, and filter-aware graph generation.
- Define packet/latency/throughput-oriented timeline views needed for v1 troubleshooting workflows.
- Cover drill-down from graph points or ranges back to packet subsets.

## Requirements
- Graph calculations must stay consistent with the active display filter and capture time base.
- Users must be able to move from graph insight back to specific packets or conversations.
- The views must remain performant on large captures.

## Dependencies
- v0.5.3 conversations and endpoints windows.
- v0.9.1 large capture performance.

## Tests
- Unit tests: cover bucket generation, throughput/latency calculations, and time-range mapping.
- Integration tests: cover graph outputs across bursty, idle, retransmission-heavy, and filtered fixture traces.
- UI tests: out of scope.

## Out Of Scope
- Machine-learning anomaly graphs.
- Protocol-specific statistics suites beyond v1 scope.
