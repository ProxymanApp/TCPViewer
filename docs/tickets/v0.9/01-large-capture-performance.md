# v0.9.1 Large Capture Performance

## Summary
Define the dedicated performance work needed for large captures, including indexing, lazy bytes loading, background aggregation, and cancellation.

## What To Build
- Specify indexing and caching strategies for large traces.
- Define lazy bytes loading, deferred decode, and background stats/graph computation.
- Establish performance targets and cancellation behavior for expensive work.

## Requirements
- Large captures must remain navigable without exhausting memory unnecessarily.
- Background work must be cancelable and must not corrupt document state.
- Performance improvements must preserve correctness and repeatability.

## Dependencies
- v0.3.5 large file loading v1.
- v0.5.3 conversations and endpoints windows.
- v0.6.4 transport analysis views.

## Tests
- Unit tests: cover index state, cache invalidation, and cancellation logic.
- Integration tests: cover repeated loading and analysis of large fixture captures under memory-pressure-aware scenarios.
- UI tests: out of scope.

## Out Of Scope
- DPDK or non-macOS high-speed capture engines.
- Distributed trace processing.
