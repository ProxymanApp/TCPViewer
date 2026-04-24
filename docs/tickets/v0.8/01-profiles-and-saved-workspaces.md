# v0.8.1 Profiles And Saved Workspaces

## Summary
Define reusable analyst profiles and workspace settings for columns, filters, colors, decode-as rules, and layout preferences.

## What To Build
- Specify profile and workspace models plus storage expectations.
- Define how saved filters, colors, column presets, and decode-as rules attach to profiles.
- Cover import/export or migration considerations only as needed for v1 stability.

## Requirements
- Profiles must be durable across app relaunches and upgrades.
- Workspace data must not corrupt open capture documents.
- The design must support multiple analysis personas without hard-coding a single default setup.

## Dependencies
- v0.4.2 filter UX and saved filters.
- v0.4.4 column system and presets.
- v0.5.4 coloring rules v1.
- v0.6.3 decode-as and protocol overrides.

## Tests
- Unit tests: cover profile persistence, merge behavior, and workspace restore logic.
- Integration tests: cover switching profiles across open traces and reopening saved workspaces after relaunch.
- UI tests: out of scope.

## Out Of Scope
- Cloud sync or profile sharing.
- Team collaboration features.
