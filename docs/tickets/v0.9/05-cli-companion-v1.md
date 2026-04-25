# v0.9.5 CLI Companion v1

## Summary
Define a command-line companion for batch open/analyze/export workflows so advanced users can automate TCPViewer-style analysis outside the GUI.

## What To Build
- Specify the CLI surface for opening traces, applying saved filters, exporting summaries, and batch analysis.
- Define how the CLI reuses core parsing, filter, and export logic from shared modules.
- Cover output formats and failure behavior suitable for scripting and CI.

## Requirements
- The CLI must share core logic with the app instead of reimplementing analysis rules.
- Output must be deterministic and automation-friendly.
- The v1 surface should stay focused on trace analysis and export, not full interactive capture control.

## Dependencies
- v0.9.3 export surface and handoff.
- v0.4.1 display filter engine v1.

## Tests
- Unit tests: cover argument parsing, command validation, and output-model formatting.
- Integration tests: cover batch analysis and export commands against fixture traces.
- UI tests: out of scope.

## Out Of Scope
- Remote capture orchestration.
- MCP server behavior.
