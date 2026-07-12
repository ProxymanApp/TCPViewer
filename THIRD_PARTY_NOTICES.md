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

## Transitive Runtime Libraries

`scripts/bootstrap-wireshark-deps.sh` builds Wireshark's non-system runtime
dependency closure from pinned source archives into
`Vendor/.install/wireshark-deps`, and `scripts/stage-wireshark-runtime.sh`
recursively stages those repo-built dynamic libraries. Before publishing a
binary release, inspect the generated
`OpenSourceLicenses/RUNTIME_LIBRARIES.txt` file inside the app bundle and make
sure every non-system runtime library has its required license notice included
with the release.
