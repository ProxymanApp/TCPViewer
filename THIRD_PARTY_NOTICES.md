# Third-Party Notices

TCP Viewer links native packet parsing libraries for capture, packet storage,
and deep packet inspection.

## Wireshark

- Source: https://gitlab.com/wireshark/wireshark
- Pinned tag: `v4.6.4`
- Pinned peeled commit: `93282876538d78a2927108dd71ee0ff370aedb0a`
- License: GPL-2.0-or-later
- Local source path: `Vendor/Wireshark`
- Local build/install path: `Vendor/.install/wireshark`

Wireshark's `libwireshark`, `libwiretap`, and `libwsutil` provide the planned
deep packet detail backend. The bootstrap script installs these libraries into
the local vendor install directory.

## PcapPlusPlus

- Source: https://github.com/seladb/PcapPlusPlus
- Pinned tag: `v25.05`
- Pinned commit: `a49a79e0b67b402ad75ffa96c1795def36df75c8`
- License: Unlicense
- Local source path: `Vendor/PcapPlusPlus`
- Local build/install path: `Vendor/.install/pcapplusplus`

PcapPlusPlus remains TCP Viewer's capture, packet summary, file I/O, and
fallback detail engine while Wireshark-backed inspection is rolled in.
