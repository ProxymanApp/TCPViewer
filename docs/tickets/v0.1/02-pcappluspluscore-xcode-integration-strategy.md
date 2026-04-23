# v0.1.2 PcapPlusPlusCore Xcode Integration Strategy

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
- Unit tests: cover facade-level wrapper behavior once the core target exists.
- Integration tests: validate loading of the packaged/vendored core on Apple Silicon and Intel-compatible build settings.
- UI tests: out of scope.

## Out Of Scope
- Full feature work on capture or parsing.
- Packaging and notarization details.
