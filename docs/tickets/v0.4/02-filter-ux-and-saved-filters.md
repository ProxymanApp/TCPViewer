# v0.4.2 Filter UX And Saved Filters

## Summary
Define the analyst-facing filter experience around the display-filter engine, including history, saved filters, macros, and field discovery hooks.

## What To Build
- Model recent filters, saved filters, and filter macros.
- Define validation feedback, autocomplete-ready field inventory, and error presentation.
- Specify how filters are shared with other workflows like follow stream, conversations, and protocol hierarchy.

## Requirements
- Saved filters must be durable and profile-friendly.
- Macros must stay within the supported v1 filter surface and fail predictably.
- The UX must make it easy to distinguish valid, invalid, and incomplete filters.

## Dependencies
- v0.4.1 display filter engine v1.
- v0.1.5 app architecture baseline.

## Tests
- Unit tests: cover saved-filter persistence, macro expansion, and validation-state logic.
- Integration tests: cover applying saved filters and macros to real fixture traces and reopening them from profiles later.
- UI tests: out of scope.

## Out Of Scope
- Capture-filter UX.
- Full protocol-field reference documentation.
