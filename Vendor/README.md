# Vendor Layout

- `Vendor/PcapPlusPlus/`: upstream git submodule pinned by the main repository.
- `Vendor/Wireshark/`: upstream Wireshark checkout pinned by `scripts/bootstrap-wireshark.sh`.
- `Vendor/.build/`: local or CI CMake build products for vendored native dependencies.
- `Vendor/.install/`: staged install output consumed by Xcode build settings.

`Vendor/.build/` and `Vendor/.install/` are intentionally ignored so the repository stores source pins, not generated artifacts.

After `scripts/bootstrap-wireshark.sh` succeeds, `PcapPlusPlusCore.framework`
bundles the staged Wireshark runtime libraries in its own
`Versions/A/Frameworks` directory for Debug and Release builds. Wireshark's
non-system runtime dependency closure is built from source by
`scripts/bootstrap-wireshark-deps.sh` into `Vendor/.install/wireshark-deps` so
the app does not ship Homebrew bottle dylibs tied to the release machine's OS.

```sh
xcodebuild -project TCPViewer.xcodeproj -scheme TCPViewer build
```
