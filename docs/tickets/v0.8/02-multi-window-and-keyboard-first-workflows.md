# v0.8.2 Multi-Window And Keyboard-First Workflows

## Summary
Define serious desktop workflows for multiple trace windows and keyboard-driven analysis so Packetry feels native and efficient during long sessions.

## What To Build
- Specify multi-window document behavior and window ownership of analysis state.
- Define keyboard-first navigation for filters, packet movement, follow stream, and summary views.
- Cover command-menu and shortcut expectations at a high level.

## Requirements
- Multiple windows must not leak state across unrelated traces.
- Keyboard workflows must complement, not replace, standard macOS interactions.
- The design must remain compatible with saved workspaces and document restoration.

## Dependencies
- v0.1.5 app architecture baseline.
- v0.8.1 profiles and saved workspaces.

## Tests
- Unit tests: cover document-state isolation and shortcut-routing logic where model-driven.
- Integration tests: cover opening multiple traces, switching focus, and preserving per-window analysis state.
- UI tests: out of scope.

## Out Of Scope
- iPad-style multi-scene support.
- Collaboration across windows.
