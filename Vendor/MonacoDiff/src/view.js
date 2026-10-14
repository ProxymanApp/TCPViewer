// Only plaintext comparisons and their presentation settings belong in this embedded editor.
export function createDiff(monaco, container, stopWorkers) {
  const editor = monaco.editor.createDiffEditor(container, {
    automaticLayout: true,
    readOnly: true,
    originalEditable: false,
    domReadOnly: true,
    renderSideBySide: true,
    useInlineViewWhenSpaceIsLimited: false,
    ignoreTrimWhitespace: false,
    renderIndicators: true,
    renderMarginRevertIcon: false,
    enableSplitViewResizing: true,
    diffAlgorithm: 'advanced',
    maxComputationTime: 5000,
    minimap: { enabled: false },
    stickyScroll: { enabled: false },
    wordWrap: 'off',
    scrollBeyondLastLine: false,
    fontFamily: 'Menlo, Monaco, monospace',
    links: false,
    selectionHighlight: true,
    unicodeHighlight: { ambiguousCharacters: false },
    stopRenderingLineAfter: 50000,
    overviewRulerBorder: false,
    scrollbar: { alwaysConsumeMouseWheel: false, horizontalSliderSize: 8, verticalSliderSize: 8 }
  });
  const original = monaco.editor.createModel('', 'plaintext');
  const modified = monaco.editor.createModel('', 'plaintext');
  for (const model of [original, modified]) model.updateOptions({ tabSize: 4, insertSpaces: false });
  editor.setModel({ original, modified });

  // Remember the pane when AppKit handles Command-F before WebKit receives the key event.
  let focusedPane = editor.getModifiedEditor();
  const listeners = [editor.getOriginalEditor(), editor.getModifiedEditor()].map(pane =>
    pane.onDidFocusEditorText(() => { focusedPane = pane; })
  );
  let disposed = false;
  return {
    editor,
    render({ left, right, sideBySide }) {
      if (disposed) return;
      editor.updateOptions({ renderSideBySide: sideBySide, ignoreTrimWhitespace: false });
      // Reuse two models so mode, theme, and pool updates cannot accumulate packet snapshots.
      if (original.getValue() !== left) original.setValue(left);
      if (modified.getValue() !== right) modified.setValue(right);
      if (!sideBySide) focusedPane = editor.getModifiedEditor();
      editor.layout();
      editor.getOriginalEditor().render(true);
      editor.getModifiedEditor().render(true);
    },
    appearance({ dark, fontSize }) {
      if (disposed) return;
      monaco.editor.setTheme(dark ? 'vs-dark' : 'vs');
      editor.updateOptions({ fontSize });
    },
    find() {
      if (disposed) return;
      focusedPane.focus();
      focusedPane.getAction('actions.find').run();
    },
    navigate(backwards) {
      if (disposed) return;
      editor.getModifiedEditor().focus();
      editor.goToDiff(backwards ? 'previous' : 'next');
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      listeners.forEach(listener => listener.dispose());
      editor.dispose();
      original.dispose();
      modified.dispose();
      stopWorkers();
    }
  };
}
