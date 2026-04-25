# App Architecture Baseline

## Goal
Give TCPViewer one stable app-side state model before live capture, file ingest, and analyst UI features expand. The foundation contract is one window-scoped controller per workspace, background services behind protocol boundaries, and immutable snapshots handed to SwiftUI.

## Window Ownership
- Every window owns one `TCPViewerWindowController`.
- The controller publishes a `TCPViewerWindowSnapshot` value instead of exposing mutable service state directly to the view layer.
- Snapshot state is split into `CaptureAccessState`, `CaptureDocumentState`, and `CaptureSessionState` so later tickets can evolve each concern independently.

## Service Boundaries
- `TCPViewerServiceRegistry` injects app-side dependencies and the `PcapPlusPlusCore` facade.
- `TCPViewer` talks to `TCPViewerCoreProviding` only; no app type depends on vendored native wrappers.
- `TCPViewerBackgroundCoordinator` is an actor that tracks background operations and provides a single cancellation surface for future file-open, decode, and live-capture tasks.

## Concurrency Rules
- SwiftUI observes the controller on the main actor only.
- Background file ingest, capture, and decode work must happen off the main actor and report back by replacing the window snapshot with a new value.
- Cancellation is modeled explicitly at the controller boundary so long-running work can stop without leaving stale UI state behind.

## Model Baseline
- `CaptureDocumentState` tracks document phase, file URL, packet count, and reopenability.
- `CaptureSessionState` tracks live-capture phase, selected interface, packet count, status messaging, and the last core error.
- `TCPViewerWindowSnapshot` is the stable bundle the UI reads and tests assert against.
- `PacketSummary` and `CaptureInterfaceSummary` stay in `PcapPlusPlusCore`; app state stores those values rather than re-wrapping raw native objects.

## Multi-Window And Future Growth
- Window-local state is independent by design so later multi-window and saved-workspace work does not need to untangle a global singleton.
- Shared services may be cached below `TCPViewerServiceRegistry`, but selected packet state, document state, and onboarding state remain window-scoped.
- This baseline intentionally avoids final visual design and performance tuning; it only locks ownership and update flow.

## v0.1 Outputs
- The app target now contains starter document/session/window models plus a controller that demonstrates the snapshot pattern.
- `ContentView` renders foundation-state summaries instead of the stock template, proving the controller can drive SwiftUI without leaking native details.
- Deployment settings are normalized to macOS `14.0` so the project stops inheriting the accidental template baseline.
