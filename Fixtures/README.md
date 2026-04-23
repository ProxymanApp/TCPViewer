# Packetry Fixture Catalog

This directory stores shared capture inputs and golden expectations used by both `PacketryTests` and `PcapPlusPlusCoreTests`.

- `manifest.json` defines the current fixture schema and the starter category list.
- `captures/` holds raw `pcap` and `pcapng` inputs.
- `goldens/` holds expected summaries, metadata snapshots, and future stats outputs.

The initial `v0.1` scaffold creates the folder structure and lookup helpers without checking in large captures yet.
