# Vendor Layout

- `Vendor/PcapPlusPlus/`: upstream git submodule pinned by the main repository.
- `Vendor/Wireshark/`: upstream Wireshark checkout pinned by `scripts/bootstrap-wireshark.sh`.
- `Vendor/.build/`: local or CI CMake build products for vendored native dependencies.
- `Vendor/.install/`: staged install output consumed by Xcode build settings.

`Vendor/.build/` and `Vendor/.install/` are intentionally ignored so the repository stores source pins, not generated artifacts.

After `scripts/bootstrap-wireshark.sh` succeeds, Debug builds link the staged Wireshark libraries by default:

```sh
xcodebuild -project TCPViewer.xcodeproj -scheme TCPViewer build
```
