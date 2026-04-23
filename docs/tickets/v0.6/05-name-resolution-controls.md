# v0.6.5 Name Resolution Controls

## Summary
Define optional name resolution for MAC addresses, IPs, and services so analysts can switch between human-friendly views and exact raw values deliberately.

## What To Build
- Model toggles and settings for MAC, network, and service-name resolution.
- Specify how resolved names and raw values are displayed together or separately.
- Define caching, invalidation, and fallback behavior.

## Requirements
- Name resolution must be optional and transparent to the user.
- Resolved values must never silently replace raw values in a misleading way.
- The design must work in packet rows, details, conversations, endpoints, and exports.

## Dependencies
- v0.4.4 column system and presets.
- v0.5.3 conversations and endpoints windows.

## Tests
- Unit tests: cover setting persistence, formatting behavior, and cache invalidation rules.
- Integration tests: cover MAC, host, and service resolution behavior on representative traces with and without resolution enabled.
- UI tests: out of scope.

## Out Of Scope
- External asset databases beyond what is needed for v1 name resolution.
- Geolocation features.
