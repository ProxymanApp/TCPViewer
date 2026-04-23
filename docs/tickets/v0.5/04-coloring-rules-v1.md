# v0.5.4 Coloring Rules v1

## Summary
Define the first coloring system so analysts can visually triage important traffic such as SYN, FIN, RST, retransmits, DNS, and TLS quickly.

## What To Build
- Specify built-in coloring rules and a model for user-defined rules.
- Define precedence and conflict handling when multiple rules match.
- Cover storage so coloring rules can become profile-aware later.

## Requirements
- Coloring must be deterministic and cheap enough for large packet lists.
- Built-in rules should reflect common transport debugging workflows.
- User-defined rules must align with the supported display-filter surface.

## Dependencies
- v0.4.1 display filter engine v1.
- v0.4.4 column system and presets.

## Tests
- Unit tests: cover rule matching, precedence, and persistence behavior.
- Integration tests: cover coloring of representative TCP, DNS, TLS, and retransmission fixture traces.
- UI tests: out of scope.

## Out Of Scope
- Full profile management.
- Accessibility color-audit work beyond basic contrast awareness.
