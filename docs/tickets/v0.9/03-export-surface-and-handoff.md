# v0.9.3 Export Surface And Handoff

## Summary
Define the broader export surface so analysts can hand off selected packets, streams, tables, bytes, and summaries to other tools or teammates.

## What To Build
- Specify export targets for selected packets, streams, tables, raw bytes, and summary formats such as CSV, text, and JSON.
- Define how exports preserve context such as filters, timestamps, and trace origins where useful.
- Cover failure behavior and overwrite/collision handling.

## Requirements
- Exported data must be predictable and traceable back to the capture.
- Export formats must support automation and human review.
- The design must work with name resolution and profile settings without hiding raw data unexpectedly.

## Dependencies
- v0.5.2 follow stream workflows.
- v0.5.3 conversations and endpoints windows.
- v0.8.3 macOS packet metadata surface.

## Tests
- Unit tests: cover export format mapping, filename rules, and option validation.
- Integration tests: cover packet, stream, table, and summary export round-trips from representative traces.
- UI tests: out of scope.

## Out Of Scope
- Cloud uploads or external sharing services.
- Full report templating.
