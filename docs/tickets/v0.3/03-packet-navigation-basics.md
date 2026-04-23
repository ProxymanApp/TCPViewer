# v0.3.3 Packet Navigation Basics

## Summary
Define the first navigation workflows that let analysts move quickly through a trace by packet number, selection movement, and field-linked jumps.

## What To Build
- Support next/previous packet navigation and packet-number jump behavior.
- Define field selection sync between the detail tree and bytes pane.
- Establish entry points for future packet search features.

## Requirements
- Navigation must behave consistently for both filtered and unfiltered packet lists.
- Selection movement must be deterministic during live capture updates.
- The design must leave room for bookmarks, marks, and search results later.

## Dependencies
- v0.3.1 main three-pane analysis window.
- v0.3.2 core packet decode surface.

## Tests
- Unit tests: cover next/previous navigation, jump validation, and selection synchronization.
- Integration tests: cover navigation behavior on live-updating and offline packet sets.
- UI tests: out of scope.

## Out Of Scope
- Full-text or byte search results UI.
- Packet triage actions.
