# Vendor Layout

- `Vendor/PcapPlusPlus/`: upstream git submodule pinned by the main repository.
- `Vendor/.build/`: local or CI CMake build products for vendored native dependencies.
- `Vendor/.install/`: staged install output consumed by future Xcode integration work.

`Vendor/.build/` and `Vendor/.install/` are intentionally ignored so the repository stores source pins, not generated artifacts.
