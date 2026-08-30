# tcpviewer-cli

`tcpviewer-cli` automates TCP Viewer without linking Wireshark or the capture core into the command-line process. JSON is the default output and the stable automation interface.

The executable is bundled at `TCP Viewer.app/Contents/MacOS/tcpviewer-cli`. Homebrew installations expose it on `PATH`:

```bash
brew install --cask tcp-viewer
tcpviewer-cli --version
```

When TCP Viewer is closed, `--help`, `--version`, argument validation, and `app status` run locally. Other commands launch the app without activating it and leave it running. `packets reveal` is the one command that activates the app intentionally.

## Commands

```text
tcpviewer-cli app status
tcpviewer-cli interfaces list

tcpviewer-cli capture status
tcpviewer-cli capture start --interface ID [--bpf EXPRESSION]
tcpviewer-cli capture pause
tcpviewer-cli capture resume
tcpviewer-cli capture stop

tcpviewer-cli packets list [QUERY OPTIONS]
tcpviewer-cli packets summary [QUERY OPTIONS]
tcpviewer-cli packets details PACKET_ID [--max-depth 0...12] [--max-nodes 1...5000]
tcpviewer-cli packets bytes PACKET_ID [--offset N] [--length 1...65536] [--encoding base64|hex]
tcpviewer-cli packets clear --yes
tcpviewer-cli packets reveal PACKET_ID

tcpviewer-cli stream packets STREAM_ID [QUERY OPTIONS]
tcpviewer-cli stream follow PACKET_ID [--direction both|client-to-server|server-to-client] [--encoding text|hex|base64]

tcpviewer-cli file import PATH...
tcpviewer-cli file export PATH --format pcap|pcapng (--all | QUERY SELECTOR) [--overwrite]
tcpviewer-cli file export-session PATH [--overwrite]

tcpviewer-cli license status
tcpviewer-cli license activate
tcpviewer-cli license revoke --yes

tcpviewer-cli settings list
tcpviewer-cli settings get KEY
tcpviewer-cli settings set KEY VALUE
tcpviewer-cli settings reset KEY
tcpviewer-cli settings reset --all --yes
```

Every leaf command accepts `--output json|text`, `--pretty`, and `--timeout SECONDS`. The normal timeout is 30 seconds. License commands use 60 seconds; import, export, and TCP follow use 300 seconds. A timed-out long operation may still finish in the app.

Start begins a new capture and clears the active packet workspace. `--bpf` is a persistent libpcap capture filter for future traffic, not a query over packets already captured.

Packet byte output defaults to base64. Use `--encoding hex` only when a hexadecimal representation is more convenient.

`file import` accepts one or more `.pcap`/`.pcapng` files, or one `.tcpviewsession` by itself. A session replaces the current workspace. Export never replaces an existing regular file unless `--overwrite` is present, and it refuses symbolic-link destinations.

License activation never accepts a key argument. Pipe one key through standard input or enter it at the non-echoing prompt:

```bash
printf '%s\n' "$TCPVIEWER_LICENSE_KEY" | tcpviewer-cli license activate
tcpviewer-cli license activate
```

Do not place license keys in scripts, committed files, shell arguments, or logs.

## Packet queries

These repeatable selectors are available to packet list/summary, stream packets, and packet export:

- `--protocol NAME`
- `--domain TEXT`
- `--address TEXT`
- `--port NUMBER`
- `--client TEXT`
- `--packet-id DECIMAL_ID`
- `--stream-id NUMBER` (one value)
- `--filter FIELD:OPERATOR:VALUE`

Advanced filters split only their first two colons, so IPv6 values remain intact:

```bash
tcpviewer-cli packets list --filter 'source_address:equals:2001:db8::1' --limit 25
```

Supported fields are `packet_id`, `packet_number`, `protocol`, `domain`, `source_address`, `destination_address`, `address`, `source_port`, `destination_port`, `port`, `client`, `bundle_id`, `direction`, `decode_status`, `info`, `interface`, `stream_id`, `length`, `tcp_flags`, `truncated`, and `text`.

Supported operators are `equals`, `not_equals`, `contains`, `not_contains`, `starts_with`, `ends_with`, `greater_than`, `greater_than_or_equal`, `less_than`, `less_than_or_equal`, and `exists`.

`--match and|or` controls only the advanced filter group. Protocol, domain, packet ID, and stream selectors are always ANDed with that group. Use `--case-sensitive` for advanced text filters.

Queries return recent packets first unless `--order oldest` is used. Bounds are:

- At most 20 advanced/address/port/client filters.
- Result `--limit` defaults to 50 and is capped at 500.
- Scan `--scan-limit` defaults to 50,000 and is capped at 100,000.
- Continue result pages with `--offset` from `next_offset`.
- Continue scan windows with `--scan-offset` from `next_scan_offset`.

For selector-based file exports, `--limit` and `--offset` page the matched selection. `--all` exports the bounded scan and ignores result pagination.

TCP follow scans at most 250,000 candidate packets and returns at most 4 MiB or 10,000 records.

## Settings

The supported keys are:

| Key | Values |
|---|---|
| `theme` | `system`, `light`, `dark` |
| `packet_font_size` | `10` through `24` |
| `monospaced_font` | Boolean |
| `analytics` | Boolean |
| `crash_reports` | Boolean |
| `quit_confirmation` | Boolean |
| `mcp_enabled` | Boolean |
| `mcp_redaction` | Boolean |

Boolean values accept `true`/`false`, `yes`/`no`, `on`/`off`, or `1`/`0`.

## JSON contract

Success is written to standard output:

```json
{"schema_version":1,"request_id":"...","ok":true,"command":"capture.start","data":{}}
```

Failure is written to standard error:

```json
{"schema_version":1,"request_id":"...","ok":false,"command":"capture.start","error":{"code":"app_command_failed","message":"..."}}
```

Schema version 1 uses decimal strings for packet IDs, ISO 8601 timestamps, base64 for requested binary output, and lowercase snake-case enum values. License keys and receipt signatures are never returned. New optional fields may be added within schema version 1; existing field meanings and types remain stable.

Exit codes are:

| Code | Meaning |
|---:|---|
| `0` | Success |
| `2` | Command usage or argument validation error |
| `3` | App launch, transport, or timeout failure |
| `4` | TCP Viewer rejected or failed the command |

The app and CLI exchange UUID-correlated JSON files under `~/Library/Application Support/TCPViewer/CLI` and signal work with Darwin notifications. Directories are private to the user and stale responses are cleaned after 24 hours. The transport does not use XPC, sockets, or the MCP HTTP server.
