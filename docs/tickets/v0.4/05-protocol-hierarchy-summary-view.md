# v0.4.5 Protocol Hierarchy Summary View

## Summary
Define a protocol hierarchy view that summarizes protocol mix in a trace and helps users drill into specific traffic quickly.

## What To Build
- Specify the hierarchy model, counts, bytes, and filter handoff behavior.
- Define how the view aggregates packets by protocol and sub-protocol where supported.
- Support navigation from summary rows back into filtered packet views.

## Requirements
- Aggregation must be consistent with the active packet set and display filter state.
- Unknown or partially decoded packets must still be represented sensibly.
- The view must remain performant on large captures.

## Dependencies
- v0.3.2 core packet decode surface.
- v0.4.1 display filter engine v1.

## Tests
- Unit tests: cover hierarchy aggregation rules and filter expression generation.
- Integration tests: cover hierarchy results across mixed-protocol fixture traces and filtered subsets.
- UI tests: out of scope.

## Out Of Scope
- Detailed protocol statistics suites beyond the hierarchy summary.
- Expert diagnostics integration.
