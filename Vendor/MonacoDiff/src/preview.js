// A read-only HTTP message (request or response) with syntax highlighting, shown in the packet Preview popover.

// JSON body tokens; the app pretty-prints the body before it arrives.
const jsonRules = [
  [/"(?:[^"\\]|\\.)*"(?=\s*:)/, 'http.json.key'],
  [/"(?:[^"\\]|\\.)*"/, 'http.json.string'],
  [/-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/, 'http.json.number'],
  [/\b(?:true|false|null)\b/, 'http.json.literal'],
  [/[{}[\],:]/, 'http.delimiter']
];

// Monarch runs its rules on empty lines too, so the blank line after the headers switches to the body.
function httpLanguage(bodyRules) {
  return {
    defaultToken: '',
    tokenizer: {
      root: [
        // With groups, every character belongs to a group. Monarch skips the action of an empty last
        // group (it stops at the end of the line), so the state change rides on a group that is never empty.
        [/^([A-Z][A-Z-]*)(\s+)(\S+)(\s+)(HTTP\/[\d.]+\s*)$/,
          ['http.method', '', 'http.target', '', { token: 'http.version', next: '@headers' }]],
        [/^(HTTP\/[\d.]+)(\s+)(\d{3})(.*)$/, ['http.version', '', {
          cases: {
            '2\\d\\d': { token: 'http.status.success', next: '@headers' },
            '3\\d\\d': { token: 'http.status.redirect', next: '@headers' },
            '4\\d\\d': { token: 'http.status.client', next: '@headers' },
            '@default': { token: 'http.status.server', next: '@headers' }
          }
        }, 'http.reason']],
        // A body-only preview (an HTTP/2 DATA frame) starts with the body itself.
        { include: '@body' }
      ],
      headers: [
        [/^$/, { token: '', next: '@body' }],
        // HTTP/2 pseudo-headers (:authority, :scheme) keep their leading colon in the name.
        [/^(:?[^:\s][^:]*)(:)(.*)$/, ['http.header.name', 'http.delimiter', 'http.header.value']],
        [/.*$/, 'http.header.value']
      ],
      body: bodyRules
    }
  };
}

const lightRules = [
  { token: 'http.method', foreground: '0550AE', fontStyle: 'bold' },
  { token: 'http.target', foreground: '1F2328' },
  { token: 'http.version', foreground: '6E7781' },
  { token: 'http.status.success', foreground: '1A7F37', fontStyle: 'bold' },
  { token: 'http.status.redirect', foreground: '9A6700', fontStyle: 'bold' },
  { token: 'http.status.client', foreground: 'BC4C00', fontStyle: 'bold' },
  { token: 'http.status.server', foreground: 'CF222E', fontStyle: 'bold' },
  { token: 'http.reason', foreground: '1F2328' },
  { token: 'http.header.name', foreground: '8250DF' },
  { token: 'http.header.value', foreground: '0A3069' },
  { token: 'http.delimiter', foreground: '6E7781' },
  { token: 'http.json.key', foreground: '0550AE' },
  { token: 'http.json.string', foreground: '0A3069' },
  { token: 'http.json.number', foreground: '116329' },
  { token: 'http.json.literal', foreground: 'CF222E' }
];

const darkRules = [
  { token: 'http.method', foreground: '6CB6FF', fontStyle: 'bold' },
  { token: 'http.target', foreground: 'E6EDF3' },
  { token: 'http.version', foreground: '8B949E' },
  { token: 'http.status.success', foreground: '57AB5A', fontStyle: 'bold' },
  { token: 'http.status.redirect', foreground: 'C69026', fontStyle: 'bold' },
  { token: 'http.status.client', foreground: 'F69D50', fontStyle: 'bold' },
  { token: 'http.status.server', foreground: 'F47067', fontStyle: 'bold' },
  { token: 'http.reason', foreground: 'E6EDF3' },
  { token: 'http.header.name', foreground: 'DCBDFB' },
  { token: 'http.header.value', foreground: '96D0FF' },
  { token: 'http.delimiter', foreground: '8B949E' },
  { token: 'http.json.key', foreground: '79C0FF' },
  { token: 'http.json.string', foreground: 'A5D6FF' },
  { token: 'http.json.number', foreground: '7EE787' },
  { token: 'http.json.literal', foreground: 'FF7B72' }
];

export function createPreview(monaco, container) {
  monaco.languages.register({ id: 'http-message' });
  monaco.languages.setMonarchTokensProvider('http-message', httpLanguage([[/.*$/, '']]));
  monaco.languages.register({ id: 'http-message-json' });
  monaco.languages.setMonarchTokensProvider('http-message-json', httpLanguage(jsonRules));
  monaco.editor.defineTheme('tcpviewer-http-light', { base: 'vs', inherit: true, rules: lightRules, colors: {} });
  monaco.editor.defineTheme('tcpviewer-http-dark', { base: 'vs-dark', inherit: true, rules: darkRules, colors: {} });

  const model = monaco.editor.createModel('', 'http-message');
  const editor = monaco.editor.create(container, {
    model,
    automaticLayout: true,
    readOnly: true,
    domReadOnly: true,
    wordWrap: 'on',
    wrappingIndent: 'indent',
    minimap: { enabled: false },
    stickyScroll: { enabled: false },
    folding: false,
    glyphMargin: false,
    lineDecorationsWidth: 8,
    lineNumbersMinChars: 3,
    renderLineHighlight: 'none',
    scrollBeyondLastLine: false,
    fontFamily: 'Menlo, Monaco, monospace',
    links: false,
    occurrencesHighlight: 'off',
    unicodeHighlight: { ambiguousCharacters: false },
    stopRenderingLineAfter: 50000,
    overviewRulerBorder: false,
    scrollbar: { alwaysConsumeMouseWheel: false, horizontalSliderSize: 8, verticalSliderSize: 8 }
  });
  model.updateOptions({ tabSize: 2, insertSpaces: true });

  let disposed = false;
  return {
    editor,
    render({ text, json }) {
      if (disposed) return;
      monaco.editor.setModelLanguage(model, json ? 'http-message-json' : 'http-message');
      if (model.getValue() !== text) model.setValue(text);
      editor.setScrollPosition({ scrollTop: 0, scrollLeft: 0 });
    },
    appearance({ dark, fontSize }) {
      if (disposed) return;
      monaco.editor.setTheme(dark ? 'tcpviewer-http-dark' : 'tcpviewer-http-light');
      editor.updateOptions({ fontSize });
    },
    find() {
      if (disposed) return;
      editor.focus();
      editor.getAction('actions.find').run();
    },
    // Token types of one line, so tests can check the highlighting without reading the DOM.
    tokenTypes(lineNumber) {
      return monaco.editor.tokenize(model.getValue(), model.getLanguageId())[lineNumber - 1].map(token => token.type);
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      editor.dispose();
      model.dispose();
    }
  };
}
