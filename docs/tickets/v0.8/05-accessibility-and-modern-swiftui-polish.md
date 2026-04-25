# v0.8.5 Accessibility And Modern SwiftUI Polish

## Summary
Define the accessibility, visual consistency, and SwiftUI refinement work needed for TCP Viewer to feel like a polished native macOS application.

## What To Build
- Establish accessibility expectations for labels, focus order, keyboard navigation, and readable data-dense layouts.
- Define visual polish goals for typography, spacing, pane behavior, and inspector surfaces.
- Set boundaries for "modern SwiftUI" so implementation stays grounded in public APIs.

## Requirements
- Accessibility work must apply across the core analysis workflow, not just isolated screens.
- Dense packet data must remain readable and efficient to scan.
- The design must support prolonged professional use rather than novelty UI.

## Dependencies
- v0.3.1 main three-pane analysis window.
- v0.8.2 multi-window and keyboard-first workflows.

## Tests
- Unit tests: cover accessibility-related model decisions where applicable, such as label formatting and command-state logic.
- Integration tests: cover keyboard navigation and workspace restoration behavior that affects accessibility and consistency.
- UI tests: out of scope.

## Out Of Scope
- Brand/marketing site design.
- Experimental unreleased platform APIs.
