# v0.8.3 macOS Packet Metadata Surface

## Summary
Define how Packetry surfaces macOS-specific packet metadata such as process info, flow IDs, packet metadata, and drop information when present in captures.

## What To Build
- Model macOS-specific metadata fields and their availability states.
- Define where these fields appear in packet details, summaries, or dedicated metadata views.
- Cover how the app behaves when metadata is absent or only partially present.

## Requirements
- macOS-specific metadata must remain optional and clearly labeled.
- The feature must not break generic packet parsing when metadata is unavailable.
- Export and filter hooks should be considered for fields that are practical in v1.

## Dependencies
- v0.3.2 core packet decode surface.
- v0.4.1 display filter engine v1.

## Tests
- Unit tests: cover metadata mapping and availability-state formatting.
- Integration tests: cover metadata-containing fixture traces and traces without metadata to ensure graceful fallback.
- UI tests: out of scope.

## Out Of Scope
- Process attribution beyond what the capture data actually contains.
- Endpoint-security style live process inspection.
