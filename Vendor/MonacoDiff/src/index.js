import * as monaco from 'monaco-editor/editor/editor.api.js';
import '../node_modules/monaco-editor/esm/vs/base/browser/ui/codicons/codicon/codicon.css';
import 'monaco-editor/editor/browser/widget/diffEditor/diffEditor.contribution.js';
import 'monaco-editor/features/find/register.js';
import 'monaco-editor/editor/contrib/clipboard/browser/clipboard.js';
import 'monaco-editor/editor/contrib/contextmenu/browser/contextmenu.js';
import 'monaco-editor/editor/contrib/readOnlyMessage/browser/contribution.js';
import 'monaco-editor/editor/contrib/wordOperations/browser/wordOperations.js';
import 'monaco-editor/editor/contrib/wordHighlighter/browser/wordHighlighter.js';
import 'monaco-editor/editor/contrib/toggleTabFocusMode/browser/toggleTabFocusMode.js';
import workerSource from 'diff-worker-source';
import { createDiff } from './view.js';
import { createPreview } from './preview.js';
import './styles.css';

const workers = new Set();
globalThis.MonacoEnvironment = {
  getWorker() {
    const url = URL.createObjectURL(new Blob([workerSource], { type: 'text/javascript' }));
    const worker = new Worker(url);
    URL.revokeObjectURL(url);
    workers.add(worker);
    const terminate = worker.terminate.bind(worker);
    worker.terminate = () => { workers.delete(worker); terminate(); };
    return worker;
  }
};

// One bundle serves two pages: index.html (Packet Diff) and preview.html (HTTP message Preview).
const diffContainer = document.getElementById('diff');
if (diffContainer) {
  window.tcpviewerDiff = createDiff(monaco, diffContainer, () => {
    for (const worker of workers) worker.terminate();
    workers.clear();
  });
}
const previewContainer = document.getElementById('preview');
if (previewContainer) {
  window.tcpviewerPreview = createPreview(monaco, previewContainer);
}
