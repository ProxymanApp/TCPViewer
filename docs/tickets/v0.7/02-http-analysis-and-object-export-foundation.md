# v0.7.2 HTTP Analysis And Object Export Foundation

## Summary
Define the HTTP/1.x analysis model that adds request-response correlation, reassembled headers/bodies, and the groundwork for object export.

## What To Build
- Specify HTTP request/response pairing and metadata models.
- Define how reassembled headers and bodies appear in the detail and follow-stream views.
- Establish the object-export foundation without requiring the full export UI yet.

## Requirements
- HTTP analysis must integrate with TCP reassembly and decode-as rules.
- Correlation must handle missing requests, missing responses, and partial bodies explicitly.
- The feature must remain limited to HTTP/1.x for v1.

## Dependencies
- v0.6.1 TCP reassembly and IP defragmentation.
- v0.6.3 decode-as and protocol overrides.

## Tests
- Unit tests: cover request-response pairing, header/body mapping, and partial-message representation.
- Integration tests: cover normal, chunked, partial, and non-standard-port HTTP fixture traces.
- UI tests: out of scope.

## Out Of Scope
- HTTP/2 and HTTP/3.
- Full object-export UI and export policy.
