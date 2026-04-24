# PcapPlusPlusCore Integration Strategy

## Goal
Define one reproducible way to bring `PcapPlusPlus` into Packetry so the app target stays pure Swift while `PcapPlusPlusCore` owns all native interop, error translation, and unsafe lifetime management.

## Source Layout
- `Vendor/PcapPlusPlus/` is a git submodule pinned to upstream tag `v25.05` at commit `a49a79e0b67b402ad75ffa96c1795def36df75c8`.
- `Vendor/.build/pcapplusplus/` is the local or CI CMake build directory for native outputs.
- `Vendor/.install/pcapplusplus/` is the staged install prefix for headers and libraries if Xcode integration needs a stable include/lib root.
- `PcapPlusPlusCore/` contains the Swift-importable facade plus the future ObjC++ and C++ glue that talks to vendored headers.

## Boundary Rules
- `Packetry` never imports vendored headers, C++ symbols, or ObjC++ wrapper types.
- `PcapPlusPlusCore` is the only target allowed to include `PcapPlusPlus` headers or link directly against vendored native outputs.
- Public APIs exposed by `PcapPlusPlusCore` must be pure Swift value types, enums, structs, and protocols.
- C++ exceptions, pointer ownership, packet buffers, and third-party lifetime rules are translated to `PacketryCoreError` inside `PcapPlusPlusCore`.
- If Swift C++ interoperability is enabled later, it remains scoped to `PcapPlusPlusCore` leaf wrappers only. The app target still consumes plain Swift models.

## Native Wrapper Shape
- Use small ObjC++ or C++ shim objects to own native handles and translate exceptions.
- Keep one wrapper responsibility per concern: interface discovery, capture session lifecycle, file ingest, decode tree generation, and filter compilation.
- Swift-facing service protocols sit above those shims and return stable app-facing models such as `CaptureInterfaceSummary`, `PacketSummary`, and filter-validation results.
- No wrapper should leak raw packet pointers or buffer-backed storage into SwiftUI-facing code.

## Build Strategy
- Local bootstrap:

```bash
./scripts/bootstrap-pcapplusplus.sh
```

- CI uses the same source path, build directory, and install prefix so local and CI failures happen against the same layout.
- Generated artifacts stay out of git; reproducibility comes from the submodule pin plus the bootstrap script validating `v25.05` at `a49a79e0b67b402ad75ffa96c1795def36df75c8`.
- The initial `v0.1` scaffold does not yet link these outputs into Xcode. That wiring lands in later runtime tickets once the native bridge is implemented.

## Toolchain And Platform Expectations
- Packetry targets macOS `14.0` as the explicit baseline for app and test targets.
- `PcapPlusPlusCore` keeps `gnu++20` in Xcode so future shims can coexist with the project default while remaining compatible with upstream's CMake-driven native build.
- Local debug builds may use the active architecture, but CI and release validation must build both `arm64` and `x86_64`.
- Apple Silicon is the primary developer platform; Intel compatibility is preserved through dual-arch native builds and fixture-backed tests.

## Immediate v0.1 Outputs
- The repo now carries the pinned submodule path under `Vendor/PcapPlusPlus`.
- `PcapPlusPlusCore` exports starter Swift protocols and value types that future native wrappers must satisfy.
- The app can begin building against stable facade types without taking a direct dependency on native packet-library details.
