# v0.7.4 WebSocket-Over-TCP Inspection

## Summary
Define limited WebSocket inspection for traffic TCP Viewer can identify directly or through HTTP upgrade context and decode-as support.

## What To Build
- Specify WebSocket detection, frame summaries, and basic message-direction views.
- Define how detection works via HTTP upgrade context or explicit decode-as overrides.
- Cover partial captures and unsupported frame cases gracefully.

## Requirements
- WebSocket inspection must be explicit about detection confidence.
- The feature must not promise broad protocol support outside the v1 scope.
- The model must support packet-list drill-down and stream follow integration.

## Dependencies
- v0.7.2 HTTP analysis and object export foundation.
- v0.6.3 decode-as and protocol overrides.

## Tests
- Unit tests: cover upgrade detection, frame summary mapping, and fallback behavior.
- Integration tests: cover standard and non-standard-port WebSocket fixture traces with complete and partial upgrades.
- UI tests: out of scope.

## Out Of Scope
- WebSocket compression and extension deep support.
- WebSocket object export.
