# Spicy adapter seam

Phase 2 keeps Spicy optional and out of the app link step until the first generated parser lands.
The C++ core exposes `SpicyParserAdapter` in `PacketDissectionEngine.hpp`; adapters receive:

- protocol identity (`DNS`, `TLS`, `HTTP1`, or `WebSocket`)
- parser name intended for generated modules, such as `TCPViewer::HTTP1`
- payload bytes and base packet offset

Adapters return native `DetailNode` values with byte and bit ranges, so generated Spicy parsers can feed the same inspector tree as the built-in dissectors.

Current build behavior:

- No `spicyc` invocation is required.
- No Spicy runtime is linked.
- Native Phase 2 dissectors remain the fallback when no adapter supports a protocol.

When a generated parser is added, compile it ahead of time with Spicy's C++ output path and wrap the generated entry point in a `SpicyParserAdapter` implementation.
