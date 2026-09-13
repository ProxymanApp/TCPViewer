# TCP Viewer MCP commands

MCP and `tcpviewer-cli` use the same app command handlers. MCP requires TCP Viewer to be running with PRO authorization and MCP Server enabled. The CLI keeps its existing background launch and licensing behavior.

Start with `list_workspaces` or `list_tabs` to discover `workspace_id`, `tab_id`, and `pane_id`. Add these optional selectors to capture, packet, export, and analysis commands. Missing selectors use the current selection. Explicit targets preserve the selected tab and focused pane; invalid or stale IDs fail.

| Tools | Purpose |
|---|---|
| `list_workspaces`, `list_tabs` | Discover live/offline tabs, ordering, selected IDs, and primary/secondary panes |
| `create_tab`, `select_tab`, `move_tab`, `close_tab` | Create, select, reorder, and close tabs |
| `get_pane`, `update_pane`, `focus_pane` | Read and update source selection, filters, selected packet, and Packets/Overview mode |
| `set_split_view` | Explicitly enable or disable a second pane with `enabled` |
| `list_sources` | Page through source IDs for apps, domains, files, and other sidebar selections |
| `get_overview_statistics` | Read complete Overview dashboard data without opening its view |
| `get_endpoint_statistics` | Read Apps, Domains, IPv4, IPv6, TCP, or UDP endpoint statistics |
| `follow_stream` | Read the TCP/UDP stream containing a packet, including DNS traffic |
| `import_capture`, `export_session` | Import capture files into offline tabs and export targeted sessions |

Existing tools remain available. `get_capture_overview` still returns capture status and controls. `query_packets` remains a read-only packet query; `update_pane` changes the app's display filters. `start_capture.capture_filter` is the separate persistent BPF filter controlling future collection.

## Example workflow

These are `tools/call` parameter objects. Discover the workspace and its tabs first:

```json
{"name":"list_workspaces","arguments":{}}
```

```json
{"name":"list_tabs","arguments":{"workspace_id":"WORKSPACE_UUID"}}
```

```json
{"name":"create_tab","arguments":{"workspace_id":"WORKSPACE_UUID"}}
```

```json
{"name":"set_split_view","arguments":{"tab_id":"TAB_UUID","enabled":true}}
```

```json
{"name":"get_pane","arguments":{"pane_id":"SECONDARY_PANE_UUID"}}
```

```json
{"name":"list_sources","arguments":{"pane_id":"SECONDARY_PANE_UUID","limit":50}}
```

```json
{"name":"update_pane","arguments":{"pane_id":"SECONDARY_PANE_UUID","quick_filters":["dns"],"mode":"packets"}}
```

```json
{"name":"query_packets","arguments":{"pane_id":"SECONDARY_PANE_UUID","scope":"displayed","limit":20}}
```

```json
{"name":"get_endpoint_statistics","arguments":{"pane_id":"SECONDARY_PANE_UUID","scope":"displayed","group":"udp","sort":"bytes","order":"desc","limit":50}}
```

```json
{"name":"follow_stream","arguments":{"tab_id":"TAB_UUID","packet_id":"123","protocol":"udp","encoding":"text"}}
```

```json
{"name":"get_overview_statistics","arguments":{"tab_id":"TAB_UUID"}}
```

Selection and ordering are explicit actions:

```json
{"name":"select_tab","arguments":{"tab_id":"TAB_UUID"}}
```

```json
{"name":"focus_pane","arguments":{"pane_id":"SECONDARY_PANE_UUID"}}
```

```json
{"name":"move_tab","arguments":{"tab_id":"TAB_UUID","index":0}}
```

```json
{"name":"import_capture","arguments":{"paths":["/tmp/example.pcapng"],"tab_id":"TAB_UUID","confirm":true}}
```

```json
{"name":"export_session","arguments":{"tab_id":"TAB_UUID","path":"/tmp/example.tcpviewsession"}}
```

```json
{"name":"close_tab","arguments":{"tab_id":"TAB_UUID","confirm":true}}
```

Replace UUID placeholders with discovery results and packet IDs with query results. New tabs remain unselected unless `select=true`. Import defaults to creating and selecting an offline tab; explicit replacement preserves selection and requires `confirm=true`. Closing the last tab stops capture and closes its window. Additional tabs and opening split view keep their PRO restrictions.

Pane updates preserve omitted fields. `packet_id=null` clears selection. Empty display/Wireshark strings or an empty structured-filter group clear those filters. `quick_filters=[]` clears protocol quick filters. Endpoint statistics rows return an `endpoint` object that can be passed unchanged to `update_pane`; `endpoint=null` clears that drill-down filter. See [CLI command reference](CLI.md) for filter fields, groups, sorting, limits, and equivalent shell commands.

## Privacy and bounded work

All new MCP responses honor the current redaction setting. Follow Stream returns record metadata with `payload_redacted=true` and omits each record's `data` field while redaction is enabled. Raw stream payloads require redaction to be disabled in settings. Privacy is checked again before asynchronous results are returned.

Follow Stream retains the 250,000-candidate, 4 MiB, and 10,000-record limits. Endpoint and source lists return at most 500 rows per page. Overview uses the same bounded top lists and timeline as the dashboard. Complete-source analysis reads bounded packet chunks through a fixed watermark and permits one analysis per source at a time. It does not install recurring full-capture scans or open Statistics/Follow windows.

Changes to a target's capture or lifetime can cancel a pending command. An analysis that cannot reconcile metadata changes returns an error instead of inconsistent totals. Analysis has a 100-second work deadline; the MCP bridge retains its existing command timeout. Long native operations may finish after a transport timeout.
