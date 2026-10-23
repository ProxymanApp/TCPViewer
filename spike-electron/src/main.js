// Electron main process for the spike: owns the window, the engine process, and metrics, never packet data.
'use strict';

const { app, BrowserWindow, MessageChannelMain, ipcMain, screen, utilityProcess } = require('electron');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ENGINE_NAME = 'TCPViewer Engine';
const METRICS_INTERVAL_MS = 500;

// Without this, performance.memory in the renderer is bucketed and useless for the report.
app.commandLine.appendSwitch('enable-precise-memory-info');

const config = parseConfig(process.argv);
const metricSamples = [];
let mainWindow = null;
let engine = null;
let metricsTimer = null;

// Read bench flags; anything malformed keeps its default.
function parseConfig(argv) {
  const parsed = { bench: argv.includes('--bench'), rate: 100000, phaseSeconds: 6, pingSeconds: 3, warmupSeconds: 3 };
  const keys = {
    '--rate': 'rate',
    '--phase-seconds': 'phaseSeconds',
    '--ping-seconds': 'pingSeconds',
    '--warmup-seconds': 'warmupSeconds',
  };
  for (const arg of argv) {
    const [flag, raw] = arg.split('=');
    const key = keys[flag];
    const value = Number(raw);
    if (key && Number.isFinite(value) && value > 0 && value <= 1000000) {
      parsed[key] = value;
    }
  }
  return parsed;
}

// Fork the native engine into its own utility process.
function startEngine() {
  engine = utilityProcess.fork(path.join(__dirname, 'engine.js'), [], { serviceName: ENGINE_NAME, stdio: 'inherit' });
  engine.on('exit', (code) => {
    console.log(`engine exited with code ${code}`);
  });
}

// Create the sandboxed window and give it a direct MessagePort to the engine.
function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    title: 'TCP Viewer Electron Spike',
    backgroundColor: '#1b1d21',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false,
      spellcheck: false,
    },
  });
  // Keep the bench window visible so occlusion throttling cannot skew frame timing.
  if (config.bench) {
    mainWindow.setAlwaysOnTop(true, 'floating');
  }
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (event) => event.preventDefault());

  const { port1, port2 } = new MessageChannelMain();
  const connectEngine = () => engine.postMessage({ type: 'connect' }, [port1]);
  if (engine.pid) {
    connectEngine();
  } else {
    engine.once('spawn', connectEngine);
  }
  mainWindow.webContents.once('did-finish-load', () => {
    mainWindow.webContents.postMessage('engine-port', null, [port2]);
  });
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

// Record per-process CPU time and memory. Cumulative CPU seconds are used instead of percentCPUUsage, which
// Electron normalizes across all cores and which reads 0 for light processes under Windows' 15.6 ms tick accounting.
function sampleMetrics() {
  const at = Date.now();
  for (const metric of app.getAppMetrics()) {
    metricSamples.push({
      at,
      pid: metric.pid,
      key: metric.type === 'Utility' ? `Utility:${metric.name || metric.serviceName || 'unknown'}` : metric.type,
      cpuSeconds: metric.cpu.cumulativeCPUUsage ?? null,
      workingSetKB: metric.memory.workingSetSize,
      privateKB: metric.memory.privateBytes ?? null,
    });
  }
}

// CPU as % of one core (100 = one full core) and peak memory per process kind inside one phase's window.
function summarizeProcesses(startAt, endAt) {
  const byPid = new Map();
  for (const sample of metricSamples) {
    if (sample.at < startAt || sample.at > endAt) {
      continue;
    }
    const samples = byPid.get(sample.pid) ?? [];
    samples.push(sample);
    byPid.set(sample.pid, samples);
  }
  // Processes of the same kind (for example two Utility services with one name) are summed.
  const byKey = new Map();
  for (const samples of byPid.values()) {
    const first = samples[0];
    const last = samples[samples.length - 1];
    const seconds = (last.at - first.at) / 1000;
    const cpuCorePercent = seconds > 0 && first.cpuSeconds !== null && last.cpuSeconds !== null
      ? ((last.cpuSeconds - first.cpuSeconds) / seconds) * 100
      : null;
    const entry = byKey.get(first.key) ?? { cpuCorePercent: 0, workingSetMaxMB: 0, privateMaxMB: null };
    entry.cpuCorePercent = cpuCorePercent === null ? entry.cpuCorePercent : entry.cpuCorePercent + cpuCorePercent;
    entry.workingSetMaxMB += Math.max(...samples.map((sample) => sample.workingSetKB)) / 1024;
    if (first.privateKB !== null) {
      entry.privateMaxMB = (entry.privateMaxMB ?? 0) + Math.max(...samples.map((sample) => sample.privateKB)) / 1024;
    }
    byKey.set(first.key, entry);
  }
  const summary = {};
  for (const [key, entry] of byKey) {
    summary[key] = {
      cpuCorePercent: round(entry.cpuCorePercent),
      workingSetMaxMB: round(entry.workingSetMaxMB),
      privateMaxMB: entry.privateMaxMB === null ? null : round(entry.privateMaxMB),
    };
  }
  return summary;
}

// Describe the machine, display, and GPU path so results from different hosts are comparable.
async function environmentInfo() {
  const display = screen.getPrimaryDisplay();
  let gpuInfo = null;
  try {
    gpuInfo = await Promise.race([
      app.getGPUInfo('complete'),
      new Promise((resolve) => setTimeout(() => resolve(null), 5000)),
    ]);
  } catch {
    gpuInfo = null;
  }
  const aux = gpuInfo?.auxAttributes ?? {};
  return {
    platform: process.platform,
    arch: process.arch,
    osRelease: os.release(),
    osVersion: typeof os.version === 'function' ? os.version() : null,
    cpuModel: os.cpus()[0]?.model ?? null,
    cpuCount: os.cpus().length,
    totalMemoryGB: round(os.totalmem() / 2 ** 30),
    electron: process.versions.electron,
    chrome: process.versions.chrome,
    node: process.versions.node,
    display: { refreshHz: display.displayFrequency, scaleFactor: display.scaleFactor, size: display.size },
    gpuFeatureStatus: app.getGPUFeatureStatus(),
    gpu: gpuInfo
      ? {
          devices: (gpuInfo.gpuDevice ?? []).map((device) => ({
            vendorId: device.vendorId,
            deviceId: device.deviceId,
            active: device.active,
            deviceString: device.deviceString,
            driverVendor: device.driverVendor,
            driverVersion: device.driverVersion,
          })),
          glRenderer: aux.glRenderer ?? null,
          glImplementationParts: aux.glImplementationParts ?? null,
          softwareRendering: aux.softwareRendering ?? null,
        }
      : null,
  };
}

// Keep the console line short: one row per phase with the headline numbers.
function compactSummary(report) {
  return {
    platform: `${report.environment.platform}-${report.environment.arch}`,
    gpu: report.environment.gpu?.glRenderer ?? null,
    refreshHz: report.environment.display.refreshHz,
    phases: report.phases.map((phase) => ({
      phase: phase.encoding === 'none' ? phase.name : `${phase.name}/${phase.encoding}`,
      ingest: phase.ingestRowsPerSecond,
      rttP50: (phase.pingMs ?? phase.rttMs).p50,
      rttP95: (phase.pingMs ?? phase.rttMs).p95,
      fps: phase.frames.fps,
      frameP95: phase.frames.p95Ms,
      placeholderFramePct: phase.placeholderFramePercent,
      cpuCorePercent: Object.fromEntries(Object.entries(phase.processes).map(([key, value]) => [key, value.cpuCorePercent])),
    })),
  };
}

function round(value) {
  return Number.isFinite(value) ? Math.round(value * 100) / 100 : null;
}

ipcMain.handle('spike:config', () => config);

// Merge renderer results with process metrics, write the JSON report, and quit.
ipcMain.on('spike:results', async (event, results) => {
  if (!event.senderFrame?.url?.startsWith('file:') || !results || !Array.isArray(results.phases)) {
    return;
  }
  for (const phase of results.phases) {
    phase.processes = summarizeProcesses(phase.wallStart, phase.wallEnd);
  }
  const report = { generatedAt: new Date().toISOString(), environment: await environmentInfo(), config, ...results };
  const directory = path.join(__dirname, '..', 'results');
  fs.mkdirSync(directory, { recursive: true });
  const stamp = report.generatedAt.replace(/[:.]/g, '-');
  const file = path.join(directory, `bench-${process.platform}-${process.arch}-${stamp}.json`);
  fs.writeFileSync(file, JSON.stringify(report, null, 2));
  console.log(`BENCH_RESULTS ${path.basename(file)}`);
  console.log(`BENCH_SUMMARY ${JSON.stringify(compactSummary(report))}`);
  app.quit();
});

app.whenReady().then(() => {
  startEngine();
  createWindow();
  metricsTimer = setInterval(sampleMetrics, METRICS_INTERVAL_MS);
  if (config.bench) {
    const expectedSeconds = config.warmupSeconds + config.pingSeconds * 2 + config.phaseSeconds * 6;
    setTimeout(() => {
      console.error('BENCH_TIMEOUT the renderer never reported results');
      app.exit(2);
    }, (expectedSeconds + 120) * 1000);
  }
});

app.on('window-all-closed', () => app.quit());

app.on('before-quit', () => {
  clearInterval(metricsTimer);
  engine?.kill();
});
