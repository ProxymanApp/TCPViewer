# v0.1.2 PcapPlusPlusCore Xcode Integration Strategy

Status: COMPLETE

## Owned Artifacts
- [docs/architecture/pcappluspluscore-integration.md](../../architecture/pcappluspluscore-integration.md)
- [Vendor/README.md](../../../Vendor/README.md)
- `Vendor/PcapPlusPlus` git submodule pinned to `v25.05`
- [PcapPlusPlusCore/Public/PcapPlusPlusCore.swift](../../../PcapPlusPlusCore/Public/PcapPlusPlusCore.swift)
- [PcapPlusPlusCore/Models/CaptureModels.swift](../../../PcapPlusPlusCore/Models/CaptureModels.swift), [PacketModels.swift](../../../PcapPlusPlusCore/Models/PacketModels.swift), and [CoreProtocols.swift](../../../PcapPlusPlusCore/Models/CoreProtocols.swift)

## Definition Of Done
- Document the vendored source layout, native-wrapper shape, and public Swift boundary.
- Pin upstream `PcapPlusPlus` in-repo as a reproducible git submodule instead of relying on prebuilt artifacts.
- Land starter pure-Swift facade types in `PcapPlusPlusCore` so later tickets can extend stable contracts without leaking native details into the app target.

## Summary
Define how PcapPlusPlus will be vendored or built for `PcapPlusPlusCore` so Swift can consume a narrow, safe facade without leaking C++ details into the app target.

## What To Build
- Document the source layout or build artifact layout for PcapPlusPlus inside the Xcode project.
- Define the public mixed-language boundary for `PcapPlusPlusCore`.
- Lock the compiler, architecture, and C++ standard expectations for Apple Silicon and Intel macOS.

## Requirements
- `PcapPlusPlusCore` must be the only target that directly includes PcapPlusPlus headers.
- Mixed Swift/C++ interop rules must be documented before runtime work begins.
- The strategy must cover local development, CI, and reproducible builds.

## Dependencies
- v0.1.1 roadmap and docs scaffold.

## Tests
- Unit tests: cover starter facade models, filter-validation placeholders, and pinned integration metadata in `PcapPlusPlusCoreTests`.
- Integration tests: validate submodule pinning plus dual-architecture build expectations against the documented vendor layout before live-capture features begin.
- UI tests: out of scope.

## Out Of Scope
- Full feature work on capture or parsing.
- Packaging and notarization details.
