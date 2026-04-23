# v1.0.1 Stability Sweep

## Summary
Define the final stability pass across capture, filtering, reconstruction, diagnostics, app-layer analysis, export, and automation before the v1 release.

## What To Build
- Identify the highest-risk correctness, crash, and data-loss areas across the shipped surface.
- Set explicit bug-bar expectations for the stable release.
- Define regression sweeps for live capture, offline analysis, filters, reassembly, diagnostics, graphs, and exports.

## Requirements
- Stability work must prioritize correctness and analyst trust over new features.
- The sweep must include upgrade, reopen, and recovery behavior.
- Known limitations must be documented instead of silently ignored.

## Dependencies
- All prior roadmap phases.

## Tests
- Unit tests: expand coverage in the most failure-prone reducers, parsers, and facade mappings.
- Integration tests: run broad regression suites across live-capture simulations, offline traces, export paths, and decryption scenarios.
- UI tests: out of scope.

## Out Of Scope
- New major features.
- Post-v1 protocol breadth expansion.
