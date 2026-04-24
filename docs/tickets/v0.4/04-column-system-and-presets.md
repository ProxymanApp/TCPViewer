# v0.4.4 Column System And Presets

## Summary
Define a customizable packet-list column system so analysts can sort, hide, reorder, and save transport-focused views.

## What To Build
- Specify the v1 packet-list columns and their sort behavior.
- Model show-hide, reorder, width, and preset behavior.
- Define default transport-focused presets that work well for TCP/UDP inspection.

## Requirements
- Sorting must remain correct under live capture and filtering.
- Column settings must be profile-friendly for later work.
- The system must avoid locking the app into a single hard-coded list view.

## Dependencies
- v0.2.5 packet ingest model.
- v0.4.2 filter UX and saved filters.

## Tests
- Unit tests: cover column definitions, sort comparators, and preset persistence.
- Integration tests: cover sorting and column configuration on large filtered and unfiltered fixture traces.
- UI tests: out of scope.

## Out Of Scope
- Advanced graphing columns.
- Full profile management UI.
