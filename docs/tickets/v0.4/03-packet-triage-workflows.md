# v0.4.3 Packet Triage Workflows

## Summary
Define the first packet triage features that help analysts work large traces efficiently: mark, ignore, comments, bookmarks, and search by field, text, or bytes.

## What To Build
- Model mark/ignore state, packet comments, bookmarks, and search results.
- Define how ignored packets interact with filters, navigation, and statistics.
- Establish search entry points for field values, free text, and raw-byte matches.

## Requirements
- Triage state must survive document reloads where appropriate.
- Search results must be stable enough to drive navigation.
- Ignore behavior must be explicit and reversible.

## Dependencies
- v0.3.3 packet navigation basics.
- v0.4.1 display filter engine v1.

## Tests
- Unit tests: cover triage-state reducers, bookmark persistence, and search query parsing.
- Integration tests: cover comment persistence, ignore/mark effects, and navigation through search results on fixture traces.
- UI tests: out of scope.

## Out Of Scope
- Collaboration or shared comments.
- Export of annotations.
