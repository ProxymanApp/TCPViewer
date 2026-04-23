# v0.3.4 Capture Filter UX

## Summary
Define a usable capture-filter workflow with validation, recent history, and clear compile errors before live capture begins.

## What To Build
- Model capture-filter text entry, validation states, and error messages.
- Store recent capture filters and defaults per user/session as appropriate.
- Define the handshake between app UI and `PcapPlusPlusCore` filter compilation.

## Requirements
- Invalid filters must fail clearly before capture starts.
- The workflow must distinguish capture filters from later display filters.
- Validation must not require users to understand raw libpcap errors without translation.

## Dependencies
- v0.2.2 live capture session lifecycle.
- v0.2.3 capture options v1.

## Tests
- Unit tests: cover validation states, recent-history behavior, and error-model formatting.
- Integration tests: cover successful and failing filter compilation through the core facade.
- UI tests: out of scope.

## Out Of Scope
- Display filter syntax and saved display filters.
- Decode-as overrides.
