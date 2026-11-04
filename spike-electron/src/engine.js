// Utility-process engine host: forwards viewport requests to the native addon and replies over the MessagePort.
'use strict';

const path = require('path');

const addon = require(path.join(__dirname, '..', 'build', 'Release', 'tcpv_engine.node'));

const TICK_MS = 100;
const MAX_ROWS_PER_REQUEST = 2000;
const MAX_ROWS_PER_SECOND = 1000000;

let port = null;
let lastTickAt = performance.now();
let maxLoopLagMs = 0;

// Accept the renderer's MessagePort from the main process; everything after that bypasses main.
process.parentPort.on('message', (event) => {
  if (event.data?.type !== 'connect' || event.ports.length !== 1) {
    return;
  }
  port = event.ports[0];
  port.on('message', (message) => handleMessage(message.data));
  port.start();
});

// Route one renderer message; renderer input is untrusted, so shapes and numbers are validated.
function handleMessage(message) {
  if (!message || typeof message !== 'object') {
    return;
  }
  switch (message.type) {
    case 'start':
      addon.start(clampNumber(message.rate, 1, MAX_ROWS_PER_SECOND, 100000));
      break;
    case 'ping':
      port.postMessage({ type: 'pong', reqId: message.reqId });
      break;
    case 'rows':
      replyRows(message);
      break;
    case 'stats':
      port.postMessage({ type: 'stats', reqId: message.reqId, ...engineStats() });
      break;
    default:
      break;
  }
}

// Build the requested viewport slice natively and post it back with the native build time.
function replyRows(message) {
  const first = clampNumber(message.first, 0, Number.MAX_SAFE_INTEGER, 0);
  const count = clampNumber(message.n, 0, MAX_ROWS_PER_REQUEST, 0);
  const encoding = message.encoding === 'packed' ? 'packed' : 'clone';
  const startedAt = process.hrtime.bigint();
  const data = encoding === 'packed' ? addon.rowsPacked(first, count) : addon.rowsClone(first, count);
  const buildUs = Number(process.hrtime.bigint() - startedAt) / 1000;
  port.postMessage({ type: 'rows', reqId: message.reqId, gen: message.gen, encoding, first, buildUs, data });
}

// Snapshot engine-side memory so the report can separate native rows from JS heap.
function engineStats() {
  const memory = process.memoryUsage();
  return {
    count: addon.count(),
    nativeRowBytes: addon.memoryBytes(),
    rssBytes: memory.rss,
    heapUsedBytes: memory.heapUsed,
  };
}

// Coerce an untrusted value into an integer within [min, max].
function clampNumber(value, min, max, fallback) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return fallback;
  }
  return Math.min(max, Math.max(min, Math.floor(value)));
}

// Send a tiny count tick at 10 Hz and report how late this event loop ran since the last one.
setInterval(() => {
  const now = performance.now();
  maxLoopLagMs = Math.max(maxLoopLagMs, now - lastTickAt - TICK_MS);
  lastTickAt = now;
  if (port) {
    port.postMessage({ type: 'tick', count: addon.count(), loopLagMs: Math.max(0, maxLoopLagMs) });
    maxLoopLagMs = 0;
  }
}, TICK_MS);
