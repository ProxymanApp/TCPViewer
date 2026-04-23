# v0.7.5 HTTP Object Export v1

## Summary
Define the first object-export feature limited to HTTP-reassembled payloads so analysts can extract transferred files or bodies when applicable.

## What To Build
- Specify which HTTP objects are exportable in v1 and how they are identified.
- Define export metadata, filenames, collision handling, and failure behavior.
- Connect export actions back to HTTP analysis surfaces and packet context.

## Requirements
- Exported objects must be traceable back to their source packets or conversations.
- Partial or truncated objects must be labeled clearly.
- The initial scope must stay limited to HTTP-reassembled payloads.

## Dependencies
- v0.7.2 HTTP analysis and object export foundation.
- v0.6.1 TCP reassembly and IP defragmentation.

## Tests
- Unit tests: cover object selection, naming rules, and partial-export representation.
- Integration tests: cover successful, duplicate-name, and truncated HTTP object export scenarios.
- UI tests: out of scope.

## Out Of Scope
- Generic object export for all protocols.
- Browser preview tooling.
