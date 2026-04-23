# Packetry Fixture Catalog

This directory stores shared capture inputs and golden expectations used by both `PacketryTests` and `PcapPlusPlusCoreTests`.

- `manifest.json` defines the current fixture schema and the starter category list.
- `captures/` holds raw `pcap` and `pcapng` inputs.
- `goldens/` holds expected summaries, metadata snapshots, and future stats outputs.
- `captures/tcp/tcp-reassembly.pcap` exercises mixed TCP and HTTP summary mapping.
- `captures/udp/someip-sd.pcapng` exercises small UDP `pcapng` ingest and format conversion.
- `captures/malformed/partial-http-request.pcap` exercises partial decode and truncation handling.
- `captures/macos-metadata/many-interfaces-1.pcapng` and `captures/macos-metadata/ipsec.pcapng` exercise metadata-preserving `pcapng` round-trips plus `pcap` save-as behavior.
