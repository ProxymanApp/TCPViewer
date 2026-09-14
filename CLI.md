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

Every leaf command accepts `--output json|text`, `--pretty`, and `--timeout SECONDS`. The normal timeout is 30 seconds. License commands use 60 seconds; import, export, and stream follow use 300 seconds. A timed-out long operation may still finish in the app.

Start begins a new capture and clears the active packet workspace. `--bpf` is a persistent libpcap capture filter for future traffic, not a query over packets already captured.

Packet byte output defaults to base64. Use `--encoding hex` only when a hexadecimal representation is more convenient.

`file import` accepts one or more `.pcap`/`.pcapng` files, or one `.tcpviewsession` by itself. Imports open in offline tabs. Explicit tab replacement requires `--tab-id` and `--yes`. Export never replaces an existing regular file unless `--overwrite` is present, and it refuses symbolic-link destinations.

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

Stream follow scans at most 250,000 candidate packets and returns at most 4 MiB or 10,000 records.

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

## Workspaces, tabs, and panes

Commands accept `--workspace-id`, `--tab-id`, and `--pane-id` from discovery results. IDs remain valid until their object closes. Replacing an imported tab keeps its tab ID but creates new pane IDs. Invalid IDs fail instead of falling back to the active tab.

```text
tcpviewer-cli workspace list
tcpviewer-cli tabs list [--workspace-id UUID]
tcpviewer-cli tabs create [--select]
tcpviewer-cli tabs select --tab-id UUID
tcpviewer-cli tabs move INDEX --tab-id UUID
tcpviewer-cli tabs close --tab-id UUID --yes

tcpviewer-cli split set on|off --tab-id UUID
tcpviewer-cli pane get --pane-id UUID
tcpviewer-cli pane focus --pane-id UUID
tcpviewer-cli pane update --pane-id UUID [PANE OPTIONS]
tcpviewer-cli sources list --pane-id UUID [--offset N] [--limit 1...500]
```

Creating a tab leaves the selected tab unchanged unless `--select` is supplied. Tabs share the workspace's live capture. Additional tabs and opening a second split pane require PRO. Closing a split releases its second pane. Closing the last tab stops capture and closes that workspace window.

Reads and updates preserve tab selection and pane focus. `tabs select` and `pane focus` explicitly change them. Commands do not bring TCP Viewer to the foreground; `packets reveal` retains its existing foreground behavior.

Pane options are:

- `--mode packets|overview`
- `--source-id ID`, using an exact ID returned by `sources list`
- `--display-filter TEXT`, with an empty string to clear it
- `--wireshark-filter EXPRESSION`, with an empty string to clear it
- `--structured-filter-json JSON`
- Repeatable `--quick-filter ID`, or `--clear-quick-filters`
- `--packet-id DECIMAL_ID`, or `--clear-packet`
- `--endpoint-group GROUP --endpoint-key KEY`, using the `endpoint` object from a statistics row, or `--clear-endpoint`

Updates preserve omitted fields and wait for filter application before returning. These are display filters over collected packets. They do not change the BPF capture filter.

Quick-filter IDs are `all`, `tcp`, `udp`, `dns`, `http`, `tls`, `websocket`, `clientHello`, `serverHello`, and `errors`. An empty quick-filter array or `--clear-quick-filters` shows all protocols.

Structured filters use the app's existing group format. The group accepts at most five filters, and an empty `filters` array clears it:

```bash
tcpviewer-cli pane update --pane-id "$PANE_ID" \
  --structured-filter-json '{"operator":"and","filters":[{"query":"urlDomain","condition":"contains","text":"example.com","is_enabled":true}]}'
```

`operator` is `and` or `or`. A filter's optional `id` preserves its existing row ID; `is_enabled` defaults to true. Queries are `anyText`, `urlDomain`, `protocol`, `source`, `destination`, `sourcePort`, `destinationPort`, `client`, `pid`, `bundleIdentifier`, `streamID`, `direction`, `tcpFlags`, `tcpPayload`, `decodeStatus`, `interface`, `length`, `summary`, and `tags`. Conditions are `contains`, `notContains`, `hasPrefix`, `notHasPrefix`, `hasSuffix`, `notHasSuffix`, `lessThan`, `greaterThanOrEqual`, `matchesRegex`, and `notMatchesRegex`. `anyText` is a Wireshark expression and must be the only filter.

Use `--scope displayed` with packet list/summary, stream packets, or packet export to use the targeted pane's current source and filters. The default `--scope all` preserves the existing query behavior.

## Overview and endpoint statistics

```text
tcpviewer-cli overview get [--tab-id UUID]
tcpviewer-cli statistics endpoints [--pane-id UUID] [--scope all|displayed]
  [--group apps|domains|ipv4|ipv6|tcp|udp] [--search TEXT]
  [--sort COLUMN] [--order asc|desc] [--offset N] [--limit 1...500]
```

Overview returns the complete source's totals, time range, protocol breakdown, top apps and destinations, and timeline. It does not open the Overview view. Top rows include source IDs for pane selection. Overview always uses the full source; use endpoint statistics for displayed-scope analysis.

Endpoint statistics defaults to Apps, all packets, bytes descending, and 50 rows. Sort columns are `address`, `port`, `protocol`, `client`, `domain`, `packets`, `bytes`, `tx_packets`, `tx_bytes`, `rx_packets`, `rx_bytes`, and `summary`. Results include total row count, `next_offset`, group counts, traffic totals, and endpoint identifiers for drill-down. Byte and packet counters in totals use unsigned decimal strings.

Analysis uses bounded chunks and a fixed capture watermark, reported as `captured_through_packet_id` and `source_packet_count`. New live packets do not extend a running request. One analysis runs per capture at a time. Closing or replacing the source cancels it. If metadata changes cannot be reconciled within the bounded job, the command returns an error and can be retried. Overview, statistics, and pane filter operations use a 120-second CLI timeout; analysis itself stops after 100 seconds.

## Targeted follow, import, and session export

```bash
tcpviewer-cli stream follow "$PACKET_ID" --tab-id "$TAB_ID" --protocol udp --encoding hex
tcpviewer-cli file import /tmp/example.pcapng --select false
tcpviewer-cli file import /tmp/replacement.pcapng --tab-id "$TAB_ID" --yes
tcpviewer-cli file export-session /tmp/example.tcpviewsession --tab-id "$TAB_ID"
```

`stream follow --protocol auto|tcp|udp` defaults to automatic transport selection. DNS follows its underlying TCP or UDP stream. Direction and payload limits remain unchanged.

Import defaults to creating and selecting an offline tab. `--select false` leaves the current selection unchanged. Supplying `--tab-id` explicitly replaces that tab, requires `--yes`, and preserves selection by default. An explicit `--select true` selects the imported replacement. Responses include the imported tab ID. Import failures return errors without opening sheets; partial imports retain their imported-file information in the error response.
