// Sandboxed renderer for the spike: a fixed-height virtual table that pulls only the rows on screen.
'use strict';

const ROW_HEIGHT = 20;
const OVERSCAN_ROWS = 100;
// Chromium caps element height near 33.5M px, so large captures scale the scrollbar instead of growing it.
const MAX_SPACER_PX = 8000000;
const MAX_BLOCKS = 3;
const SCROLL_ROWS_PER_FRAME = 200;
// Prefetch this many frames ahead in the scroll direction so a steady fling never outruns its data.
const LOOKAHEAD_FRAMES = 4;
const MAX_LOOKAHEAD_ROWS = 1500;
const COLUMN_COUNT = 7;
const EMPTY = -1;
const PLACEHOLDER = -2;

const viewport = document.getElementById('viewport');
const spacer = document.getElementById('spacer');
const rowsLayer = document.getElementById('rows');
const rowsInner = document.getElementById('rows-inner');
const statusLine = document.getElementById('status');
const textDecoder = new TextDecoder();

const state = {
  port: null,
  config: null,
  count: 0,
  encoding: 'clone',
  tail: true,
  generation: 1,
  blocks: [],
  inFlight: null,
  nextRequestId: 1,
  pendingReplies: new Map(),
  rowEls: [],
  // The displayed first row is the source of truth; scrollTop only positions the scrollbar thumb.
  viewFirst: 0,
  viewOffset: 0,
  // Row count when tail mode last moved; a held tail renders only up to here.
  viewLimit: 0,
  previousFrameFirst: 0,
  programmaticScroll: false,
  spacerPx: -1,
  offsetPx: -1,
  lastFrameAt: null,
  driver: null,
  phaseLabel: 'interactive',
  recentTicks: [],
  ingestRate: 0,
};

let metrics = newPhaseMetrics();

// Opened straight from disk in a browser, there is no preload bridge or engine, so say how to run it instead.
if (!window.spike) {
  statusLine.textContent = 'This page is only the renderer half of the spike. Run "npm start" in spike-electron '
    + 'to open it in Electron with the native engine.';
}

// Rows from a structured-clone reply: the engine's column arrays used as they arrive.
class CloneBlock {
  constructor(first, data) {
    this.first = first;
    this.n = data.count;
    this.data = data;
  }

  number(i) {
    return this.data.numbers[i];
  }

  time(i) {
    return this.data.times[i];
  }

  length(i) {
    return this.data.lengths[i];
  }

  text(i, column) {
    const data = this.data;
    if (column === 0) return data.sources[i];
    if (column === 1) return data.destinations[i];
    if (column === 2) return data.protocols[i];
    return data.infos[i];
  }
}

// Rows from a packed reply: typed-array views plus one decoded string, sliced lazily for visible rows only.
class PackedBlock {
  constructor(buffer) {
    const header = new Uint32Array(buffer, 0, 4);
    const n = header[0];
    this.first = header[1] + header[2] * 2 ** 32;
    this.n = n;
    let offset = 16;
    this.numbers = new Float64Array(buffer, offset, n);
    offset += 8 * n;
    this.times = new Float64Array(buffer, offset, n);
    offset += 8 * n;
    this.lengths = new Uint32Array(buffer, offset, n);
    offset += 4 * n;
    this.ends = new Uint32Array(buffer, offset, 4 * n);
    offset += 16 * n;
    this.blob = textDecoder.decode(new Uint8Array(buffer, offset, header[3]));
  }

  number(i) {
    return this.numbers[i];
  }

  time(i) {
    return this.times[i];
  }

  length(i) {
    return this.lengths[i];
  }

  text(i, column) {
    const slot = i * 4 + column;
    return this.blob.slice(slot === 0 ? 0 : this.ends[slot - 1], this.ends[slot]);
  }
}

// Fresh per-phase collectors; every sample array is bounded by the phase length.
function newPhaseMetrics() {
  return {
    frames: 0,
    frameDeltas: [],
    renderMs: [],
    placeholderFrames: 0,
    tailLagRows: [],
    rttMs: [],
    pingMs: [],
    buildUs: [],
    decodeMs: [],
    replyBytes: [],
    rowsPerReply: [],
    engineLoopLagMs: [],
    longFrames: 0,
    longFrameMs: 0,
  };
}

// Accept the engine port that the preload forwards; ignore anything else posted to the window.
window.addEventListener('message', (event) => {
  if (event.source !== window || event.data !== 'engine-port' || event.ports.length !== 1 || state.port) {
    return;
  }
  state.port = event.ports[0];
  state.port.onmessage = (message) => handleEngineMessage(message.data);
  start();
});

// Build the table, start the frame loop and ingest, then run the bench or wait for keyboard input.
async function start() {
  state.config = await window.spike.getConfig();
  buildRows();
  window.addEventListener('resize', buildRows);
  observeLongFrames();
  requestAnimationFrame(frame);
  state.port.postMessage({ type: 'start', rate: state.config.rate });
  if (state.config.bench) {
    runBench(state.config).catch((error) => window.spike.reportResults({ error: String(error), phases: [] }));
  } else {
    window.addEventListener('keydown', onKeyDown);
    viewport.addEventListener('wheel', () => {
      state.tail = false;
    }, { passive: true });
    viewport.addEventListener('scroll', onUserScroll, { passive: true });
  }
}

// Interactive mode: map a user scroll back to a row, ignoring the echo of our own scrollTop writes.
function onUserScroll() {
  if (state.programmaticScroll) {
    state.programmaticScroll = false;
    return;
  }
  const position = rowPosition(scrollGeometry());
  state.viewFirst = position.first;
  state.viewOffset = position.offset;
}

// Create just enough recycled row elements to cover the visible height plus one partial row.
function buildRows() {
  const needed = Math.ceil(rowsLayer.clientHeight / ROW_HEIGHT) + 1;
  rowsInner.textContent = '';
  state.rowEls = [];
  for (let i = 0; i < needed; i++) {
    const el = document.createElement('div');
    el.className = 'row';
    const cells = [];
    for (let column = 0; column < COLUMN_COUNT; column++) {
      cells.push(el.appendChild(document.createElement('span')));
    }
    rowsInner.appendChild(el);
    state.rowEls.push({ el, cells, shown: EMPTY });
  }
}

// Current scroll extents; beyond MAX_SPACER_PX the scrollbar maps proportionally onto rows.
function scrollGeometry() {
  const totalPx = state.count * ROW_HEIGHT;
  const spacerPx = Math.min(totalPx, MAX_SPACER_PX);
  const viewHeight = viewport.clientHeight;
  const fullRows = Math.floor(viewHeight / ROW_HEIGHT);
  return {
    spacerPx,
    viewHeight,
    maxFirst: Math.max(0, state.count - fullRows),
    scaled: totalPx > MAX_SPACER_PX,
  };
}

// Translate scrollTop into the first visible row and the sub-row pixel offset.
function rowPosition(geometry) {
  const top = viewport.scrollTop;
  if (!geometry.scaled) {
    return { first: Math.min(Math.floor(top / ROW_HEIGHT), geometry.maxFirst), offset: top % ROW_HEIGHT };
  }
  const maxScroll = Math.max(1, geometry.spacerPx - geometry.viewHeight);
  return { first: Math.round(Math.min(1, top / maxScroll) * geometry.maxFirst), offset: 0 };
}

// Inverse of rowPosition: move the scrollbar thumb to match a programmatically shown row.
function scrollToRow(row, geometry) {
  const top = geometry.scaled
    ? (row / Math.max(1, geometry.maxFirst)) * Math.max(1, geometry.spacerPx - geometry.viewHeight)
    : row * ROW_HEIGHT;
  if (Math.abs(viewport.scrollTop - top) >= 1) {
    state.programmaticScroll = true;
    viewport.scrollTop = top;
  }
}

// One animation frame: move the view, ask for missing rows, and paint from cached blocks only.
function frame(now) {
  const startedAt = performance.now();
  if (state.lastFrameAt !== null) {
    metrics.frameDeltas.push(now - state.lastFrameAt);
  }
  state.lastFrameAt = now;

  const geometry = scrollGeometry();
  if (geometry.spacerPx !== state.spacerPx) {
    spacer.style.height = `${geometry.spacerPx}px`;
    state.spacerPx = geometry.spacerPx;
  }

  // Bench drivers and tail mode pick a target row; user scrolling already updated viewFirst.
  let target = null;
  if (state.driver) {
    target = state.driver(geometry);
  } else if (state.tail) {
    target = geometry.maxFirst;
  }
  const desiredFirst = target ?? state.viewFirst;
  const visibleReady = requestRowsIfNeeded(desiredFirst, desiredFirst - state.previousFrameFirst);
  // Tail waits on the old tail until the new rows land, so following live capture never flashes placeholders.
  if (target !== null && (visibleReady || !state.tail)) {
    state.viewFirst = target;
    state.viewOffset = 0;
    state.viewLimit = state.count;
    scrollToRow(target, geometry);
  }
  state.previousFrameFirst = state.viewFirst;

  const rendered = renderRows({ first: state.viewFirst, offset: state.viewOffset });

  metrics.frames++;
  if (rendered.missing > 0) {
    metrics.placeholderFrames++;
  }
  if (state.tail && rendered.lastFilled >= 0) {
    metrics.tailLagRows.push(state.count - 1 - rendered.lastFilled);
  }
  metrics.renderMs.push(performance.now() - startedAt);
  requestAnimationFrame(frame);
}

// Return whether rows covering [first, first + visible) are cached, and fetch visible rows plus overscan and
// direction-aware lookahead when they are not, with at most one request in flight (latest position wins).
function requestRowsIfNeeded(first, velocity) {
  if (state.count === 0) {
    return true;
  }
  const visibleEnd = Math.min(state.count, first + state.rowEls.length);
  // A jump farther than the lookahead cap has no useful direction, so it fetches only around the target.
  const speed = Math.abs(velocity);
  const lookahead = speed <= MAX_LOOKAHEAD_ROWS ? Math.min(MAX_LOOKAHEAD_ROWS, speed * LOOKAHEAD_FRAMES) : 0;
  const needStart = velocity < 0 ? Math.max(0, first - lookahead) : first;
  const needEnd = velocity > 0 ? Math.min(state.count, visibleEnd + lookahead) : visibleEnd;
  const visibleReady = isCached(first, visibleEnd);
  if (!state.port || state.inFlight || isCached(needStart, needEnd)) {
    return visibleReady;
  }
  const start = Math.max(0, needStart - OVERSCAN_ROWS);
  const end = Math.min(state.count, needEnd + OVERSCAN_ROWS);
  const reqId = state.nextRequestId++;
  state.inFlight = { reqId, sentAt: performance.now() };
  state.port.postMessage({ type: 'rows', reqId, gen: state.generation, encoding: state.encoding, first: start, n: end - start });
  return visibleReady;
}

// True when one cached block holds every row in [start, end).
function isCached(start, end) {
  return end <= start || state.blocks.some((block) => block.first <= start && block.first + block.n >= end);
}

// Paint recycled rows; a row is only rewritten when the packet it shows changes.
function renderRows(position) {
  if (position.offset !== state.offsetPx) {
    rowsInner.style.transform = `translateY(${-position.offset}px)`;
    state.offsetPx = position.offset;
  }
  let missing = 0;
  let lastFilled = -1;
  let block = null;
  const limit = state.tail ? Math.min(state.count, state.viewLimit) : state.count;
  for (let i = 0; i < state.rowEls.length; i++) {
    const row = state.rowEls[i];
    const index = position.first + i;
    if (index >= limit) {
      if (row.shown !== EMPTY) clearRow(row, EMPTY, 'row');
      continue;
    }
    if (row.shown === index) {
      lastFilled = index;
      continue;
    }
    if (!block || index < block.first || index >= block.first + block.n) {
      block = state.blocks.find((candidate) => index >= candidate.first && index < candidate.first + candidate.n) ?? null;
    }
    if (!block) {
      if (row.shown !== PLACEHOLDER) clearRow(row, PLACEHOLDER, 'row placeholder');
      missing++;
      continue;
    }
    fillRow(row, block, index - block.first, index);
    lastFilled = index;
  }
  return { missing, lastFilled };
}

// Write one packet's columns with textContent only; packet strings are untrusted.
function fillRow(row, block, i, index) {
  const cells = row.cells;
  cells[0].textContent = String(block.number(i) + 1);
  cells[1].textContent = block.time(i).toFixed(6);
  cells[2].textContent = block.text(i, 0);
  cells[3].textContent = block.text(i, 1);
  cells[4].textContent = block.text(i, 2);
  cells[5].textContent = String(block.length(i));
  cells[6].textContent = block.text(i, 3);
  row.el.className = index % 2 ? 'row odd' : 'row';
  row.shown = index;
}

// Blank a row, optionally marking it as waiting for data.
function clearRow(row, marker, className) {
  for (const cell of row.cells) {
    cell.textContent = '';
  }
  if (marker === PLACEHOLDER) {
    row.cells[6].textContent = 'Loading…';
  }
  row.el.className = className;
  row.shown = marker;
}

// Dispatch one engine message.
function handleEngineMessage(message) {
  switch (message?.type) {
    case 'tick':
      onTick(message);
      break;
    case 'rows':
      onRows(message);
      break;
    case 'pong':
    case 'stats': {
      const resolve = state.pendingReplies.get(message.reqId);
      if (resolve) {
        state.pendingReplies.delete(message.reqId);
        resolve(message);
      }
      break;
    }
    default:
      break;
  }
}

// Apply the 10 Hz count tick and refresh the status line.
function onTick(message) {
  state.count = message.count;
  metrics.engineLoopLagMs.push(message.loopLagMs);
  const now = performance.now();
  state.recentTicks.push({ at: now, count: message.count });
  while (state.recentTicks.length > 1 && now - state.recentTicks[0].at > 1000) {
    state.recentTicks.shift();
  }
  const oldest = state.recentTicks[0];
  if (now > oldest.at) {
    state.ingestRate = Math.round(((message.count - oldest.count) * 1000) / (now - oldest.at));
  }
  statusLine.textContent = `${state.count.toLocaleString('en-US')} packets · ingest ${state.ingestRate.toLocaleString('en-US')}/s · `
    + `${state.encoding} · ${state.tail ? 'following tail' : 'manual scroll'} · ${state.phaseLabel}`;
}

// Cache a viewport block and record its round trip; replies from an older generation are dropped.
function onRows(message) {
  if (message.gen !== state.generation) {
    return;
  }
  if (state.inFlight && state.inFlight.reqId === message.reqId) {
    metrics.rttMs.push(performance.now() - state.inFlight.sentAt);
    state.inFlight = null;
  }
  metrics.buildUs.push(message.buildUs);
  let block;
  if (message.encoding === 'packed') {
    const decodeStartedAt = performance.now();
    block = new PackedBlock(message.data);
    metrics.decodeMs.push(performance.now() - decodeStartedAt);
    metrics.replyBytes.push(message.data.byteLength);
  } else {
    block = new CloneBlock(message.first, message.data);
  }
  metrics.rowsPerReply.push(block.n);
  state.blocks.unshift(block);
  if (state.blocks.length > MAX_BLOCKS) {
    state.blocks.length = MAX_BLOCKS;
  }
}

// Send a message that expects a reply with the same reqId.
function requestReply(message) {
  return new Promise((resolve) => {
    state.pendingReplies.set(message.reqId, resolve);
    state.port.postMessage(message);
  });
}

// Count long animation frames (50 ms+) as Chromium reports them.
function observeLongFrames() {
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        metrics.longFrames++;
        metrics.longFrameMs += entry.duration;
      }
    }).observe({ type: 'long-animation-frame' });
  } catch {
    // Older Chromium builds do not expose long-animation-frame entries.
  }
}

// Interactive mode: t toggles tail, e toggles the encoding.
function onKeyDown(event) {
  if (event.key === 't') {
    state.tail = !state.tail;
  } else if (event.key === 'e') {
    switchEncoding(state.encoding === 'clone' ? 'packed' : 'clone');
  }
}

// Change the reply encoding and drop blocks fetched with the old one.
function switchEncoding(encoding) {
  state.encoding = encoding;
  state.generation++;
  state.blocks = [];
  state.inFlight = null;
}

// Run every bench phase back to back while ingest continues, then report.
async function runBench(config) {
  await waitUntil(() => state.count > 0, 10000);
  state.phaseLabel = 'warm-up';
  await sleep(config.warmupSeconds * 1000);
  // Idle is the CPU baseline: ingest and 10 Hz ticks keep running, but the view stays still.
  const phases = [
    await runPhase(config, 'idle', 'none', config.pingSeconds),
    await runPhase(config, 'ping', 'none', config.pingSeconds),
  ];
  for (const encoding of ['clone', 'packed']) {
    for (const name of ['tail', 'scroll', 'jump']) {
      phases.push(await runPhase(config, name, encoding, config.phaseSeconds));
    }
  }
  state.phaseLabel = 'done';
  window.spike.reportResults({ phases, finalCount: state.count });
}

// Run one phase: tail follows new rows, scroll moves 200 rows per frame, jump lands on a random row each frame.
async function runPhase(config, name, encoding, seconds) {
  if (encoding !== 'none') {
    switchEncoding(encoding);
  }
  state.tail = name === 'tail';
  state.driver = driverFor(name);
  state.phaseLabel = encoding === 'none' ? name : `${name} / ${encoding}`;
  metrics = newPhaseMetrics();
  state.lastFrameAt = null;

  const startCount = state.count;
  const startedAt = performance.now();
  const wallStart = Date.now();
  let active = true;
  const pinging = name === 'ping' ? pingLoop(() => active) : null;
  await sleep(seconds * 1000);
  active = false;
  state.driver = null;
  await pinging;

  const elapsedSeconds = (performance.now() - startedAt) / 1000;
  const engine = await requestReply({ type: 'stats', reqId: state.nextRequestId++ });
  return summarizePhase({ config, name, encoding, elapsedSeconds, startCount, wallStart, engine });
}

// Per-frame driver returning the row a phase wants on screen, or null for phases that leave the view alone.
function driverFor(name) {
  if (name === 'scroll') {
    let row = 0;
    return (geometry) => {
      row += SCROLL_ROWS_PER_FRAME;
      if (row > geometry.maxFirst) row = 0;
      return row;
    };
  }
  if (name === 'jump') {
    return (geometry) => Math.floor(Math.random() * geometry.maxFirst);
  }
  return null;
}

// Back-to-back round trips with a tiny payload: the floor for renderer-engine latency.
async function pingLoop(isActive) {
  while (isActive()) {
    const sentAt = performance.now();
    await requestReply({ type: 'ping', reqId: state.nextRequestId++ });
    metrics.pingMs.push(performance.now() - sentAt);
  }
}

// Turn one phase's raw samples into the numbers the report needs.
function summarizePhase({ config, name, encoding, elapsedSeconds, startCount, wallStart, engine }) {
  const deltas = metrics.frameDeltas;
  const frameMs = distribution(deltas);
  const totalFrameMs = deltas.reduce((sum, value) => sum + value, 0);
  const summary = {
    name,
    encoding,
    seconds: round(elapsedSeconds),
    wallStart,
    wallEnd: Date.now(),
    ingestRowsPerSecond: Math.round((state.count - startCount) / elapsedSeconds),
    countAtEnd: state.count,
    requests: metrics.rttMs.length,
    requestsPerSecond: round(metrics.rttMs.length / elapsedSeconds),
    rttMs: distribution(metrics.rttMs),
    engineBuildUs: distribution(metrics.buildUs),
    rowsPerReply: distribution(metrics.rowsPerReply),
    frames: {
      count: deltas.length,
      fps: round(deltas.length / Math.max(0.001, totalFrameMs / 1000)),
      p50Ms: frameMs.p50,
      p95Ms: frameMs.p95,
      p99Ms: frameMs.p99,
      maxMs: frameMs.max,
      over33Ms: deltas.filter((value) => value > 33.4).length,
      over50Ms: deltas.filter((value) => value > 50).length,
    },
    rendererWorkMs: distribution(metrics.renderMs),
    placeholderFramePercent: round((100 * metrics.placeholderFrames) / Math.max(1, metrics.frames)),
    longAnimationFrames: { count: metrics.longFrames, totalMs: round(metrics.longFrameMs) },
    engineLoopLagMs: distribution(metrics.engineLoopLagMs),
    engine: {
      count: engine.count,
      nativeRowMB: round(engine.nativeRowBytes / 2 ** 20),
      rssMB: round(engine.rssBytes / 2 ** 20),
      heapUsedMB: round(engine.heapUsedBytes / 2 ** 20),
    },
    rendererHeapMB: performance.memory ? round(performance.memory.usedJSHeapSize / 2 ** 20) : null,
  };
  if (name === 'ping') {
    summary.pingMs = distribution(metrics.pingMs);
    summary.pingsPerSecond = round(metrics.pingMs.length / elapsedSeconds);
  }
  if (encoding === 'packed') {
    summary.decodeMs = distribution(metrics.decodeMs);
    summary.replyBytes = distribution(metrics.replyBytes);
  }
  if (name === 'tail') {
    const lagRows = distribution(metrics.tailLagRows);
    summary.tailLagRows = lagRows;
    summary.tailLagMs = { p50: round((lagRows.p50 * 1000) / config.rate), p95: round((lagRows.p95 * 1000) / config.rate) };
  }
  return summary;
}

// Percentiles and mean of a sample array (null fields when empty).
function distribution(values) {
  if (values.length === 0) {
    return { count: 0, p50: null, p95: null, p99: null, max: null, mean: null };
  }
  const sorted = Float64Array.from(values).sort();
  const at = (fraction) => sorted[Math.min(sorted.length - 1, Math.floor(fraction * sorted.length))];
  const mean = sorted.reduce((sum, value) => sum + value, 0) / sorted.length;
  return {
    count: sorted.length,
    p50: round(at(0.5)),
    p95: round(at(0.95)),
    p99: round(at(0.99)),
    max: round(sorted[sorted.length - 1]),
    mean: round(mean),
  };
}

function round(value) {
  return Number.isFinite(value) ? Math.round(value * 1000) / 1000 : null;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Poll a condition every 50 ms, failing after timeoutMs.
async function waitUntil(condition, timeoutMs) {
  const deadline = performance.now() + timeoutMs;
  while (!condition()) {
    if (performance.now() > deadline) {
      throw new Error('Timed out waiting for the engine to start ingesting');
    }
    await sleep(50);
  }
}
