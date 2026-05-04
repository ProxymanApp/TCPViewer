# Third-Party Notices

TCP Viewer links and bundles native packet parsing libraries for capture,
packet storage, and deep packet inspection.

When TCP Viewer is distributed with Wireshark libraries, the application is
distributed as GPL-2.0-or-later as a whole. Keep `COPYING`,
`SOURCE_CODE_OFFER.md`, and this notice file with source and binary releases.

## Wireshark

- Source: https://gitlab.com/wireshark/wireshark
- Pinned tag: `v4.6.4`
- Pinned peeled commit: `93282876538d78a2927108dd71ee0ff370aedb0a`
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

## PcapPlusPlus

- Source: https://github.com/seladb/PcapPlusPlus
- Pinned tag: `v25.05`
- Pinned commit: `a49a79e0b67b402ad75ffa96c1795def36df75c8`
- License: Unlicense
- License text: `Vendor/PcapPlusPlus/LICENSE`
- Local source path: `Vendor/PcapPlusPlus`
- Local build/install path: `Vendor/.install/pcapplusplus`

PcapPlusPlus remains TCP Viewer's capture, packet summary, file I/O, and
fallback detail engine while Wireshark-backed inspection is rolled in.

## HexFiend

- Source: https://github.com/HexFiend/HexFiend
- License: BSD-2-Clause
- License text: `Vendor/HexFiend/License.txt`
- Local binary path: `Vendor/HexFiend/HexFiend.framework`

HexFiend provides the embedded packet hex viewer framework.

## Transitive Runtime Libraries

`scripts/stage-wireshark-runtime.sh` recursively stages non-system dynamic
libraries required by the Wireshark runtime. Before publishing a binary release,
inspect the generated `OpenSourceLicenses/RUNTIME_LIBRARIES.txt` file inside the
app bundle and make sure every non-system runtime library has its required
license notice included with the release.
