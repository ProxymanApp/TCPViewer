# Third-Party Notices

TCP Viewer links and bundles native packet parsing libraries for capture,
packet storage, and deep packet inspection.

When TCP Viewer is distributed with Wireshark libraries, the application is
distributed as GPL-2.0-or-later as a whole. Keep `COPYING`,
`SOURCE_CODE_OFFER.md`, and this notice file with source and binary releases.

## Wireshark

- Source: https://gitlab.com/wireshark/wireshark
- Pinned tag: `v4.6.6`
- Pinned peeled commit: `3a22c3ef473d3f9c556d1fb13e3088c693d4fa96`
- License: GPL-2.0-or-later
- License text: `Vendor/Wireshark/COPYING`
- Local source path: `Vendor/Wireshark`
- Local build/install path: `Vendor/.install/wireshark`
- Bundled runtime libraries: `libwireshark.19.dylib`,
  `libwiretap.16.dylib`, `libwsutil.17.dylib`

Wireshark's `libwireshark`, `libwiretap`, and `libwsutil` provide the planned
deep packet detail backend. The bootstrap script installs these libraries into
the local vendor install directory. Wireshark documents that library builds are
still GPL-covered and are not LGPL.

## HexFiend

- Source: https://github.com/HexFiend/HexFiend
- License: BSD-2-Clause
- License text: `Vendor/HexFiend/License.txt`
- Local binary path: `Vendor/HexFiend/HexFiend.framework`

HexFiend provides the embedded packet hex viewer framework.

## Model Context Protocol Swift SDK

- Source: https://github.com/modelcontextprotocol/swift-sdk
- Pinned version: `0.12.1`
- License: Apache-2.0 and MIT during the upstream licensing transition;
  documentation is CC-BY-4.0
- License text: `ThirdPartyLicenses/MCP-Swift-SDK-LICENSE.txt`

The MCP Swift SDK implements the standard stdio Model Context Protocol server
used by TCP Viewer's bundled `tcpviewer-mcp` executable.

### MCP Swift SDK runtime dependencies

The bundled executable also incorporates these pinned Swift Package Manager
dependencies and includes their upstream license and NOTICE files:

- EventSource `1.4.1` (MIT): `ThirdPartyLicenses/EventSource-LICENSE.md`
- Swift System `1.7.4` (Apache-2.0): `ThirdPartyLicenses/SwiftSystem-LICENSE.txt`
- Swift Atomics `1.3.1` (Apache-2.0): `ThirdPartyLicenses/SwiftAtomics-LICENSE.txt`
- Swift Collections `1.6.0` (Apache-2.0): `ThirdPartyLicenses/SwiftCollections-LICENSE.txt`
- SwiftNIO `2.101.3` (Apache-2.0): `ThirdPartyLicenses/SwiftNIO-LICENSE.txt`
  and `ThirdPartyLicenses/SwiftNIO-NOTICE.txt`
- SwiftLog `1.14.0` (Apache-2.0): `ThirdPartyLicenses/SwiftLog-LICENSE.txt`
  and `ThirdPartyLicenses/SwiftLog-NOTICE.txt`

## Transitive Runtime Libraries

`scripts/bootstrap-wireshark-deps.sh` builds Wireshark's non-system runtime
dependency closure from pinned source archives into
`Vendor/.install/wireshark-deps`, and `scripts/stage-wireshark-runtime.sh`
recursively stages those repo-built dynamic libraries. Before publishing a
binary release, inspect the generated
`OpenSourceLicenses/RUNTIME_LIBRARIES.txt` file inside the app bundle and make
sure every non-system runtime library has its required license notice included
with the release.
