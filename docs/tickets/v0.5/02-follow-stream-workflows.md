# v0.5.2 Follow Stream Workflows

## Summary
Define follow TCP stream and follow UDP conversation workflows so TCP Viewer can reconstruct and isolate transport conversations in the MVP release.

## What To Build
- Specify stream transcript models, bidirectional presentation, and export behavior.
- Define isolate-stream filter handoff from packets, conversations, and endpoints.
- Cover how partially reconstructed or incomplete streams are represented.

## Requirements
- Follow-stream UX must work for both selected packets and summary views.
- Transcript ordering and direction labeling must be deterministic.
- Export must preserve the chosen stream representation.

## Dependencies
- v0.2.5 packet ingest model.
- v0.4.1 display filter engine v1.

## Tests
- Unit tests: cover stream-id mapping, transcript ordering, and export formatting.
- Integration tests: cover TCP and UDP conversation fixtures, including incomplete and out-of-order scenarios where applicable.
- UI tests: out of scope.

## Out Of Scope
- TCP stream analysis graphs.
- HTTP object extraction.
