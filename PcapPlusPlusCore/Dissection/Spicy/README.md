# Spicy parser plan

Phase 2 keeps Spicy optional and out of the app link step until the first generated parser lands.
The Swift core will hand parser adapters the same inputs the built-in dissector uses:

- protocol identity (`DNS`, `TLS`, `HTTP1`, or `WebSocket`)
- parser name intended for generated modules, such as `TCPViewer::HTTP1`
- payload bytes and base packet offset

Adapters should return Swift packet detail nodes with byte and bit ranges, so generated Spicy parsers can feed the same inspector tree as the built-in dissectors.

Current build behavior:

- No `spicyc` invocation is required.
- No Spicy runtime is linked.
- The Swift dissectors remain the fallback when no adapter supports a protocol.

When a generated parser is added, keep any generated native output outside `PcapPlusPlusCore` and bridge it through a small Swift-facing adapter.
