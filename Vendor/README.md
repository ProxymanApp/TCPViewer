# Vendor Layout

- `Vendor/PcapPlusPlus/`: upstream git submodule pinned by the main repository.
- `Vendor/Wireshark/`: upstream Wireshark checkout pinned by `scripts/bootstrap-wireshark.sh`.
- `Vendor/.build/`: local or CI CMake build products for vendored native dependencies.
- `Vendor/.install/`: staged install output consumed by Xcode build settings.

`Vendor/.build/` and `Vendor/.install/` are intentionally ignored so the repository stores source pins, not generated artifacts.

After `scripts/bootstrap-wireshark.sh` succeeds, enable the Wireshark backend for local builds by passing:

```sh
TCPVIEWER_HAS_WIRESHARK=1 \
TCPVIEWER_WIRESHARK_LDFLAGS="-L$(pwd)/Vendor/.install/wireshark/lib -Wl,-rpath,$(pwd)/Vendor/.install/wireshark/lib -lwireshark -lwiretap -lwsutil"
```
