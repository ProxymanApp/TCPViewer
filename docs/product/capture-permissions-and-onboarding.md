# macOS Capture Permissions And Onboarding Strategy

## Supported Capture Model
- Packetry does not run packet capture as `root`.
- Live capture depends on read or read-write access to `/dev/bpf*` on macOS.
- The supported release path uses a packaged `ChmodBPF`-style LaunchDaemon, labeled `com.proxyman.Packetry.CaptureAccess`, to repair `/dev/bpf*` ownership and permissions at boot and on demand.
- `v0.1` standardizes on `root:admin` ownership with mode `0660` so local admin users can capture without manual terminal steps. Non-admin environments are treated as unsupported until a narrower enterprise path is intentionally designed.
- The app target never performs privileged filesystem mutation directly; it only detects state, explains the issue, and deep-links into repair/install guidance.

## Onboarding States
- `firstLaunch`: user has not completed the initial capture-access guidance yet.
- `helperMissing`: the LaunchDaemon or helper package is not installed.
- `helperBroken`: the helper exists but `/dev/bpf*` ownership or mode is still incorrect.
- `accessDenied`: the current account still cannot open `/dev/bpf*` after setup.
- `noEligibleInterfaces`: Packetry can access capture devices, but no usable interfaces are currently available.
- `unsupportedInterface`: the selected or discovered interface class is outside the currently supported live-capture contract.
- `upgradeRevalidation`: a Packetry upgrade requires re-checking helper state and interface inventory before capture is enabled again.
- `repairRetryRecovery`: Packetry is waiting for the user to retry after a repair or permissions change.
- `ready`: capture prerequisites are satisfied for the supported local-user flow.

## First-Run Experience
- First launch opens in a blocked onboarding state instead of showing a generic capture failure.
- The first screen explains why macOS capture needs helper setup, what Packetry will not do, and what the user should expect next.
- Packetry offers one clear primary action for installation or repair and one secondary action to continue in offline-only mode.
- Until the helper passes validation, all live-capture entry points stay disabled and explain why.

## Upgrade And Recovery Behavior
- On version upgrades that touch capture setup, Packetry re-enters `upgradeRevalidation` before exposing live capture.
- If interface discovery succeeds but `/dev/bpf*` permissions regress, Packetry shows `helperBroken` instead of a generic runtime error.
- If the helper is fixed while Packetry is running, the app transitions into `repairRetryRecovery` and lets the user retry without relaunching the entire app.
- If the current account is not eligible for the supported `admin`-group path, Packetry shows `accessDenied` or `unsupportedInterface` with a clear explanation that the current installation contract does not cover that environment yet.

## User-Facing Messaging Rules
- Never tell users to "run Packetry as root."
- Never surface raw `libpcap` or `PcapPlusPlus` errors without app-level translation.
- Each blocked state must explain: what Packetry checked, what failed, what action fixes it, and whether offline analysis is still available.
- Hidden or unavailable interfaces are framed as inventory issues, not permission issues, unless `/dev/bpf*` access is the actual root cause.

## Detection Contract
- Helper validation checks whether the expected LaunchDaemon is installed and whether `/dev/bpf*` currently matches the supported permission model.
- Capture readiness is distinct from interface readiness; Packetry can be permission-ready while still blocked on `noEligibleInterfaces`.
- Runtime capture failures are handled separately from setup failures so later tickets can distinguish "could not start" from "lost packets after start."

## v0.1 Outputs
- The app now has pure Swift onboarding models for the supported states above.
- Later onboarding UI can bind directly to those models without embedding platform rules inside view code.
- Release-grade packaging, signed installer details, and helper implementation remain future work.
