# v0.2.3 Capture Options v1

## Status
COMPLETE

## Summary
Define the first capture-options set Packetry supports so live capture behavior is predictable and useful from the first MVP.

## What To Build
- Model options for promiscuous mode, snapshot length, buffer sizing, stop conditions, and rotating/ring capture files.
- Define validation rules and default values.
- Specify which options belong in the core facade vs app-side preference storage.

## Requirements
- Defaults must be safe for new users but flexible enough for power users.
- Option validation must happen before capture starts.
- Ring/rotating file expectations must be compatible with later save/open workflows.

## Delivered Artifacts
- `PcapPlusPlusCore/CoreFacadeTypes.swift` defines `CaptureOptions`, `CaptureStopCondition`, and `CaptureFileWriting` as `Codable` value types.
- Defaults now land at promiscuous-on except for loopback, `65535` snaplen, `4 MiB` kernel buffer, `250 ms` read timeout, manual stop, and disabled file writing.
- Validation runs before session creation and covers loopback promiscuous mode, invalid stop conditions, single/rotating/ring output requirements, and ring file count limits.
- `PcapPlusPlusCore/NativeBridgeSupport.swift` normalizes rotating and ring writers to `pcapng` when the caller omits a format.

## Verification
- `CoreFacadeTypesTests.captureDefaultsDisablePromiscuousModeForLoopback()`
- `CoreFacadeTypesTests.loopbackValidationRejectsPromiscuousOverride()`
- `CoreFacadeTypesTests.rotatingAndRingWritersDefaultToPcapngWhenNormalized()`

## Dependencies
- v0.2.1 interface inventory and selection contract.
- v0.2.2 live capture session lifecycle.

## Tests
- Unit tests: cover option validation, default selection, and serialization of option sets.
- Integration tests: cover option application to live capture sessions and ring-buffer behavior with fixture traffic.
- UI tests: out of scope.

## Out Of Scope
- Display filters.
- Offline file parsing.
