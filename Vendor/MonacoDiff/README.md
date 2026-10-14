# Embedded Packet Details Diff

This directory replaces the private MonacoEditor Swift package with TCP Viewer's
small AppKit/WebKit host and a subset of the public MIT-licensed
[Microsoft Monaco editor](https://github.com/microsoft/monaco-editor).

`MonacoDiff/` is checked in and copied as a folder resource by Xcode. Building
TCP Viewer needs **no npm install, private repository access, or web server**.
All assets, fonts, and the diff worker work offline. The web view uses an
ephemeral store, restricted local-file access, and a CSP that denies network
connections. Text crosses the WebKit bridge as data, never HTML or script source.

## Scope

- Read-only plaintext Packet Details, including indentation and whitespace changes.
- Side By Side and Unified, resizable panes, synchronized scrolling, line/word diffs.
- Find in either pane (case, whole word, regex), selection/copy, and word navigation.
- Previous/next difference through the Diff window's Shift-F7/F7 shortcuts.
- System light/dark appearance and the app's packet font size.
- Two reused text models; closing the window disposes both models and the worker.

Packet Bytes continues to use HexFiend. Diff-pool selection, external comparisons,
licensing, and persisted display mode stay in the app's existing controllers.
No language packs, language servers, completion, or scripting integration are
included. Monaco's core still contains the infrastructure required by its diff
editor; this is a focused distribution, not a fork of its diff algorithm.

## Rebuild

With Node.js 22 or later, from this directory:

```sh
npm ci --ignore-scripts
npm run build
```

Exact npm versions and integrity hashes are pinned in `package-lock.json`.
`build.mjs` bundles the editor and a self-contained blob worker, embeds the icon
font, and copies the upstream license/notices. It rejects language/completion
modules accidentally added to the bundle. Commit both source changes and rebuilt
`MonacoDiff/` assets. A normal Xcode build never runs this tooling.

The `DiffMonacoEditorIntegrationTests` in the existing app test target exercise
the real bundled runtime in WKWebView, including its worker under the file origin.
Run them along with the existing Diff tests after changing this integration.
