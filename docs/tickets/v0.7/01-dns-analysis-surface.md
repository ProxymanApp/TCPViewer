# v0.7.1 DNS Analysis Surface

## Summary
Define the first protocol-specific analysis view for DNS so Packetry can surface decoded DNS behavior beyond generic UDP/TCP payload inspection.

## What To Build
- Specify decoded DNS fields, transaction grouping, and response-timing summaries.
- Add filter shortcuts from DNS rows back into the packet list.
- Cover behavior for malformed or truncated DNS packets.

## Requirements
- DNS analysis must work for both UDP and TCP transport where supported.
- Timing summaries must clearly indicate missing requests or responses.
- The feature must stay within the focused v1 app-layer scope.

## Dependencies
- v0.3.2 core packet decode surface.
- v0.5.3 conversations and endpoints windows.

## Tests
- Unit tests: cover DNS field mapping, transaction correlation, and timing summary generation.
- Integration tests: cover successful, failed, truncated, and malformed DNS fixture traces.
- UI tests: out of scope.

## Out Of Scope
- DNS object export.
- Full DNS statistics suite beyond basic timing and filter shortcuts.
