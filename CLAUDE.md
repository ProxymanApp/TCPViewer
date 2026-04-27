# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the source of truth for coding rules; this file gives orientation. When `AGENTS.md` and this file disagree, follow `AGENTS.md`.

## Build, run, test

First-time setup (the native PcapPlusPlus dependency is a git submodule and needs CMake on the PATH — `brew install cmake`):

```bash
git submodule update --init --recursive   # or: ./scripts/bootstrap-pcapplusplus.sh
```

`scripts/bootstrap-pcapplusplus.sh` is also invoked from Xcode build phases; it stages headers/libs into `Vendor/.build/` and `Vendor/.install/pcapplusplus/`. Generated artifacts are gitignored — reproducibility comes from the submodule pin (`v25.05`, commit `a49a79e0…`) plus the script.

Build the app target after any change to TCPViewer or PcapPlusPlusCore:

```bash
xcodebuild -project TCPViewer.xcodeproj -scheme TCPViewer build
```

Run the full test plan (covers both `TCPViewerTests` and `PcapPlusPlusCoreTests`):

```bash
xcodebuild test -project TCPViewer.xcodeproj -scheme TCPViewer -destination 'platform=macOS'
```

Run a single test or class with `-only-testing:`:

```bash
xcodebuild test -project TCPViewer.xcodeproj -scheme TCPViewer -destination 'platform=macOS' \
  -only-testing:TCPViewerTests/WorkspaceControllerTests/testFooBar
```

`PcapPlusPlusCore` has its own scheme for running just the core test suite. There is no separate lint step — the Xcode build is the gate.

Xcode targets (see `xcodebuild -list`): `TCPViewer` (app), `PcapPlusPlusCore` (framework), `PcapPlusPlusCoreTests`, `TCPViewerTests`, `TCPViewerHelperTool` (privileged helper installed via SMAppService).

## Architecture

Three layers, with strict one-way dependencies:

```
TCPViewer (AppKit app) ──► PcapPlusPlusCore (Swift framework) ──► Vendor/PcapPlusPlus (C++ submodule)
                       └─► TCPViewerHelperTool (privileged daemon, plist in NetworkHelperLaunchDaemons/)
```

**`PcapPlusPlusCore/`** is the only target allowed to touch native code. `NativeBridge/TCPViewerNativeBridge.{h,mm}` is the ObjC++ shim that owns native handles and translates C++ exceptions into `TCPViewerCoreError`. All public API surfaces in `Public/` and `Models/` are pure-Swift value types. `Services/{Core,LiveCapture,OfflineCapture}/` implement the protocols declared in `Models/CoreProtocols.swift` (`TCPViewerCoreProviding`, `LiveCaptureSessionProviding`, `OfflineCaptureDocumentProviding`, etc.). These protocols are **callback-based** (`TCPViewerCompletion<T> = (Result<T, Error>) -> Void`); do not change them to `async` / `throws` — the app side relies on this shape.

**`TCPViewer/`** is the macOS app and never imports vendored headers or `_Native…` types — only the protocol facade from `PcapPlusPlusCore`.

- `App/` — `AppDelegate`, `Document` (NSDocument-based file open), settings window, main `NSWindowController` and `NSToolbar`.
- `Core/WorkspaceFoundation.swift` — the central state container. `TCPViewerWorkspaceController` owns one snapshot per window (`TCPViewerWindowSnapshot`, composed of `CaptureAccessState` + `CaptureDocumentState` + `CaptureSessionState`), publishes changes through a weak delegate, and routes background work through `TCPViewerBackgroundCoordinator`. `TCPViewerServiceRegistry` is the DI bag (`core`, `networkHelperTool`, `packetMetadataEnricher`); use `TCPViewerServiceRegistry.foundation` for production wiring and pass a custom one in tests.
- `Features/NetworkInspector/` — main viewer UI. `NetworkInspectorViewModel` is the controller-specific view-model that drives the AppKit views in `Views/` (root split view, sidebar, packet table, hex inspector, status strip). Cells and helpers live alongside.
- `Features/NetworkHelper/` — onboarding + status for the privileged helper. `TCPViewerNetworkHelperToolManager` wraps `SMAppService` to install/repair the LaunchDaemon at `NetworkHelperLaunchDaemons/com.proxyman.tcpviewer.helpertool.plist`.

**`TCPViewerHelperTool/`** runs as root to give the app raw-socket capture rights. Logic is in `TCPViewerNetworkHelperCore.swift` (testable, takes a `TCPViewerNetworkHelperPOSIXSystem` for I/O); `main.swift` is a thin entry point.

### UI and concurrency rules (also in `AGENTS.md`)

- **TCPViewer must be 100% AppKit**: `NSViewController`, `NSSplitView`, `NSTableView`, `NSToolbar`, etc. SwiftUI is allowed **only** inside `NSHostingController` for helper-tool onboarding and the settings window.
- **No Swift concurrency or Combine in TCPViewer or PcapPlusPlusCore production code**: no `Task`, `async/await`, actors, `Combine`, `Publisher`, `ObservableObject`, `@Published`, or SwiftUI bindings. Use dedicated `DispatchQueue`s for background work and return through callbacks. (Tests can still use whatever — and SwiftUI settings views are exempt because they are leaf UI islands.)
- View signaling uses **weak delegate protocols**, not bindings or notifications. Child controllers receive an explicit render model and call delegate methods for user actions.
- Do **not** add a global app state or singletons. State stays scoped to the workspace controller for the window.

### Boundary checks

When in doubt, run these to confirm nothing has leaked across the boundary:

```bash
# TCPViewer must never import vendored headers or native bridge types
grep -RIn "TCPViewerNativeBridge\|pcapplusplus\|PcapPlusPlus/" TCPViewer/

# Production code in app + core must stay free of Swift concurrency / Combine
grep -REn "(^|[^A-Za-z])(Task|async|await|Combine|Publisher|ObservableObject|@Published)\b" \
    TCPViewer/ PcapPlusPlusCore/
```

The second grep is a heuristic — string matches in comments/docs are fine; new call sites in TCPViewer or PcapPlusPlusCore are not.

## Notes for changes

- For tiny edits a build is enough; for any behavior change run the test plan. Don't write UI tests — the AGENTS.md rule is unit/integration tests only.
- The `Document.swift` / `NSDocument` flow is what wires `Open…` from the Dock or Finder into a new workspace controller; if you add a new launch entry point, make sure it goes through `TCPViewerWorkspaceController` so window-scoped state stays consistent.
- `docs/architecture/` has two longer design notes (`app-architecture-baseline.md`, `pcappluspluscore-integration.md`) — useful for context, but parts of `app-architecture-baseline.md` predate the AppKit migration (it still talks about SwiftUI observation). Treat AGENTS.md as the current rule.
