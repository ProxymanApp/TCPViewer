# Test Harness And Fixtures Strategy

## Goals
- Keep TCP Viewer's core contracts testable from the first native-integration ticket onward.
- Share one fixture catalog across app and core tests while keeping ownership boundaries explicit.
- Prefer deterministic unit and integration tests over UI automation.

## Fixture Layout
- `Fixtures/manifest.json`: catalog schema, category list, and ownership hints.
- `Fixtures/captures/<category>/`: raw `pcap` and `pcapng` inputs grouped by scenario family.
- `Fixtures/goldens/`: expected packet summaries, metadata snapshots, and future statistics outputs.

## Initial Capture Categories
- `tcp`: baseline TCP handshakes, teardown, and common stream cases.
- `udp`: stateless datagram flows and mixed source/destination cases.
- `retransmits`: duplicate ACK, retransmit, and out-of-order transport cases.
- `malformed`: truncated, corrupt, or partially decoded packets.
- `http`: HTTP/1.x request-response captures.
- `tls`: TLS handshake and encrypted payload metadata captures.
- `dns`: DNS query-response captures.
- `websocket`: upgrade plus framed traffic samples.
- `macos-metadata`: captures paired with macOS-local metadata expectations when available.

## Naming And Versioning
- Raw inputs use `v<schema>__<category>__<scenario>__input.<pcap|pcapng>`.
- Golden outputs use the same prefix plus a feature suffix such as `__summary.json` or `__stats.json`.
- Schema bumps only happen when existing fixtures need a breaking expectation change; otherwise new scenarios add new files.

## Ownership Split
- `PcapPlusPlusCoreTests` owns native-boundary model mapping, packet ingest, filter compilation, malformed data handling, and future decode-tree correctness.
- `TCPViewerTests` owns reducers, onboarding states, document/session models, fixture lookup helpers, and window-level state transitions.
- Cross-target fixtures live once under `Fixtures/`; target ownership is expressed in the manifest and the tests that consume them.

## Determinism Rules
- Packet ordering and timestamps are treated as stable unless a fixture explicitly models nondeterministic live capture.
- Tests should prefer exact equality for model state, counts, normalized filter text, and documented golden outputs.
- Large-fixture and long-running capture behavior is validated through integration tests, but the first smoke layer simply confirms the catalog is discoverable and non-empty.

## v0.1 Outputs
- The repo now has a shared fixture manifest plus starter category directories.
- Both test targets have fixture-locator helpers so later tests do not hardcode ad hoc paths.
- Starter smoke coverage validates the fixture catalog and the first foundation models without requiring UI tests.
