# v0.4.1 Display Filter Engine v1

## Summary
Define the first display-filter engine so analysts can isolate packets by protocol, address, port, flags, lengths, stream id, time, expert state, and raw-byte contains.

## What To Build
- Specify the v1 filter grammar, supported fields, and validation behavior.
- Define how filters are applied to packet summaries and later to decoded fields where supported.
- Document limitations clearly so v1 scope stays achievable.

## Requirements
- Display filters must be distinct from capture filters in both behavior and UX.
- Validation and error messages must be understandable by users.
- Filter evaluation must be compatible with large traces and future indexing work.

## Dependencies
- v0.2.5 packet ingest model.
- v0.3.2 core packet decode surface.

## Tests
- Unit tests: cover parsing, validation, and evaluation of supported display-filter expressions.
- Integration tests: cover filtering across representative TCP, UDP, malformed, and app-layer fixtures.
- UI tests: out of scope.

## Out Of Scope
- Full Wireshark display-filter language parity.
- Filter macros and saved-filter UX details beyond the engine contract.
