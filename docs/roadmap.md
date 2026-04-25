# TCP Viewer Roadmap to v1.0.0

## Product Goal
TCP Viewer is a macOS-native SwiftUI packet analyzer aimed at TCP/UDP-heavy workflows. The v1 release should cover the core analysis loop users expect from a serious Wireshark alternative: capture, filter, inspect, reconstruct, diagnose, summarize, and export.

## Deliverables In This Folder
- `docs/roadmap.md`: program-level roadmap, scope, sequencing, and release expectations.
- `docs/ticket-template.md`: shared ticket structure for future additions.
- `docs/architecture/`: architecture decisions and subsystem contracts locked during foundation work.
- `docs/product/`: user-facing behavior strategies such as onboarding, permissions, and recovery.
- `docs/testing/`: fixture catalog rules, ownership splits, and deterministic test expectations.
- `docs/tickets/v0.1/` through `docs/tickets/v1.0/`: one markdown file per implementation ticket.

## Ticket Conventions
- Every active ticket may declare `Status:` at the top of the file. `COMPLETE` means the owned artifact exists in the repo, any planned light scaffolding has landed, and the ticket's unit/integration expectations are explicit.
- Every ticket should list its owned artifact paths so future work can extend the right document, type, or folder without rediscovering where the decision lives.
- `v0.1` tickets are allowed to land documentation plus minimal scaffolding only. They do not pull runtime feature work forward from later phases.
- Future tickets should preserve stable filenames and titles so roadmap references remain durable.

## Architectural Boundaries
- `PcapPlusPlusCore` is the only target that talks directly to PcapPlusPlus, libpcap, and mixed-language glue.
- `TCPViewer` consumes a narrow Swift-importable facade only; no raw C++ types may cross into app-facing APIs.
- All C++ exceptions, pointer lifetimes, and unsafe ownership issues must be translated inside `PcapPlusPlusCore`.
- App-facing models must be stable enough for unit tests and long-term document compatibility.

## Cross-Cutting Standards
- Every runtime feature must define unit tests and integration tests.
- UI tests are out of scope for this roadmap.
- `pcap` and `pcapng` are mandatory offline formats.
- macOS permissions, capture onboarding, and Apple Silicon support are first-class product concerns.
- v1 remains transport-first, but includes focused DNS, HTTP/1.x, TLS metadata, TLS key-log decryption, and limited WebSocket inspection.

## Phase Overview

### v0.1 Foundation
Set up the planning scaffold, architecture boundaries, macOS capture strategy, and test strategy so later implementation work can proceed without re-deciding fundamentals.

Exit criteria:
- `docs/` structure is stable.
- PcapPlusPlus integration approach is documented.
- macOS capture permission strategy is defined.
- test fixture and architecture expectations are explicit.
- all `v0.1` tickets are marked `COMPLETE` with linked owned artifacts.

### v0.2 Capture Core
Build the capture engine contract, interface model, file pipeline, and ingest model required for both live and offline workflows.

Exit criteria:
- interfaces, capture lifecycle, and file workflows are well-defined.
- packet ingest models are stable enough for the UI and tests.

### v0.3 Core Inspector
Define the first analyst-facing app experience: the three-pane UI, baseline decode surface, navigation, and capture-filter validation.

Exit criteria:
- a first-pass desktop analyzer can browse packets meaningfully.

### v0.4 Filters And Triage
Add the workflows that turn packet browsing into investigation: display filters, saved filters, triage actions, column presets, and protocol hierarchy.

Exit criteria:
- analysts can isolate traffic quickly and work large traces efficiently.

### v0.5 First Working MVP
Ship the first usable desktop release with stable live capture, save/open, follow stream, conversations/endpoints, colors, and onboarding.

Exit criteria:
- a new macOS user can install, capture, inspect, and save traces without manual recovery workarounds.

### v0.6 Reconstruction And Diagnostics
Move from browsing to serious transport analysis with reassembly, defragmentation, expert diagnostics, decode-as, flow graphs, and name resolution.

Exit criteria:
- TCP Viewer can explain transport behavior instead of only listing packets.

### v0.7 App-Layer Focus Set
Add the smallest app-layer slice that materially improves day-to-day debugging: DNS, HTTP/1.x, TLS metadata/fingerprinting, WebSocket detection, and HTTP object export.

Exit criteria:
- TCP Viewer supports common backend and API debugging workflows, not just transport inspection.

### v0.8 macOS-Native Power UX
Raise the desktop experience with profiles, multi-window workflows, macOS packet metadata, Apple-friendly capture UX, and accessibility/polish.

Exit criteria:
- TCP Viewer feels native, efficient, and comfortable for long analysis sessions.

### v0.9 Scale, Export, And Automation
Harden the app for big traces and handoff workflows with performance work, timeline graphs, export surfaces, TLS decryption, and a CLI companion.

Exit criteria:
- advanced users can automate repeatable analysis and work with large captures confidently.

### v1.0.0 Stable
Stabilize the entire surface, finish documentation and release engineering, and freeze the v1 feature set.

Exit criteria:
- release-quality capture, analysis, export, documentation, signing, and migration behavior are complete.

## V1 Parity Checklist
- live local capture
- `pcap` / `pcapng` open-save
- capture filters and display filters
- three-pane packet workflow
- decode-as overrides
- TCP/UDP stream follow
- TCP reassembly and IP defragmentation
- expert diagnostics
- conversations, endpoints, protocol hierarchy, flow graph, and I/O graph
- search, mark, ignore, comments, coloring, profiles, and name resolution
- DNS, HTTP/1.x, TLS metadata, limited WebSocket inspection
- TLS key-log decryption
- HTTP object export
- CLI companion
- macOS packet/process metadata when available

## Assumptions
- v0.5 is the first working MVP desktop app, not an MCP server.
- Wireshark-scale dissector breadth is out of scope for v1.
- full wireless analysis depth, VoIP specialty tooling, Bluetooth/USB capture, remote capture, plugin ecosystems, and UI automation stay out of scope through v1.
- "Modern SwiftUI like macOS 26" means a forward-looking native macOS experience built on public APIs available at implementation time.
